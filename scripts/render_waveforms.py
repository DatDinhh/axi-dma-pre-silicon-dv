#!/usr/bin/env python3
"""Render measured DMA waveforms from scalar/vector VCD events.

Python 3 + matplotlib. Handshakes use values immediately BEFORE the rising
clock edge; post-edge nonblocking updates at that timestamp are not handshakes.
No interpolation, inferred stimulus, or invented pre-fix waveform is used.
"""
import argparse
from bisect import bisect_left, bisect_right
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


class Vcd:
    def __init__(self, path):
        self.path = Path(path)
        tokens = self.path.read_text(encoding='utf-8-sig').split()
        scopes, self.signals, self.widths, self.events = [], {}, {}, {}
        i, scale = 0, None
        while i < len(tokens):
            token = tokens[i]
            i += 1
            if token == '$enddefinitions':
                if tokens[i] != '$end':
                    raise ValueError('Malformed VCD header')
                i += 1
                break
            if token.startswith('$'):
                end = tokens.index('$end', i)
                args = tokens[i:end]
                i = end + 1
                if token == '$scope':
                    scopes.append(args[1])
                elif token == '$upscope':
                    scopes.pop()
                elif token == '$timescale':
                    match = re.fullmatch(r'(\d+)(s|ms|us|ns|ps|fs)', ''.join(args))
                    if not match:
                        raise ValueError('Unsupported VCD timescale')
                    scale = int(match[1]) * {'s':1e9,'ms':1e6,'us':1e3,'ns':1,'ps':1e-3,'fs':1e-6}[match[2]]
                elif token == '$var':
                    width, code, name = int(args[1]), args[2], args[3]
                    # ModelSim can emit individual wire bits with the same base name.
                    if len(args) > 4 and width == 1:
                        name += args[4]
                    full = '.'.join(scopes + [name])
                    if full in self.signals and self.signals[full] != code:
                        raise ValueError('Ambiguous VCD declaration: ' + full)
                    self.signals[full] = code
                    self.widths[code] = width
                    self.events.setdefault(code, [])
        if scale is None or not self.signals:
            raise ValueError('VCD lacks timescale/signals')
        self.scale_ns, time = scale, 0
        while i < len(tokens):
            token = tokens[i]
            i += 1
            if token.startswith('#'):
                next_time = int(token[1:])
                if next_time < time:
                    raise ValueError('VCD time moves backwards')
                time = next_time
                continue
            if token in ('$dumpvars', '$dumpall', '$dumpon', '$dumpoff', '$end'):
                continue
            if token.startswith('$'):
                i = tokens.index('$end', i) + 1
                continue
            if token[0].lower() == 'b':
                bits, code = token[1:].lower(), tokens[i]
                i += 1
            elif token[0].lower() in '01xz':
                bits, code = token[0].lower(), token[1:]
            else:
                raise ValueError('Unsupported VCD value: ' + token)
            if code not in self.widths or not re.fullmatch('[01xz]+', bits):
                raise ValueError('Undeclared/malformed VCD value')
            width = self.widths[code]
            bits = bits.rjust(width, bits[0] if bits[0] in 'xz' else '0')
            events = self.events[code]
            if events and events[-1][0] == time:
                events[-1] = (time, bits)
            elif not events or events[-1][1] != bits:
                events.append((time, bits))
        self.end = time
        self.times = {code:[t for t,_ in events] for code,events in self.events.items()}

    def code(self, suffix):
        matches = {code for name,code in self.signals.items() if name == suffix or name.endswith('.' + suffix)}
        if len(matches) != 1:
            raise ValueError('Missing/ambiguous signal: ' + suffix)
        return matches.pop()

    def value(self, name, time, before=False):
        code = self.code(name)
        index = (bisect_left if before else bisect_right)(self.times[code], time) - 1
        return self.events[code][index][1] if index >= 0 else 'x' * self.widths[code]

    def edges(self, name, old='0', new='1'):
        previous, result = 'x', []
        for time,bits in self.events[self.code(name)]:
            if bits == new and previous == old:
                result.append(time)
            previous = bits
        return result

    def handshakes(self, valid, ready):
        return [t for t in self.edges('clk') if self.value('rst_n',t,True) == '1'
                and self.value(valid,t,True) == self.value(ready,t,True) == '1']

    def ns(self, ticks):
        return round(ticks * self.scale_ns, 9)

    def digest(self):
        return hashlib.sha256(self.path.read_bytes()).hexdigest()


def aw_events(vcd):
    return {channel:[vcd.ns(t) for t in vcd.handshakes('axi.'+channel+'valid','axi.'+channel+'ready')]
            for channel in ('aw','w','b')}


def reset_events(vcd):
    falls = vcd.edges('rst_n','1','0')
    candidates = [t for t in falls if vcd.value('engine_busy',t,True)=='1'
                  and vcd.value('m_axi_bready',t,True)=='1' and vcd.value('m_axi_bvalid',t,True)=='0']
    if not candidates:
        raise ValueError('No reset while waiting for B response')
    reset = candidates[-1]
    release = next(t for t in vcd.edges('rst_n') if t > reset)
    restart = next(t for t in vcd.edges('engine_busy') if t > release)
    done = next(t for t in vcd.edges('sticky_done') if t > restart)
    irq = next(t for t in vcd.edges('irq') if t >= done)
    cleared = next(t for t in vcd.edges('clk') if t > reset)
    if any(vcd.value(n,cleared) != '0'*vcd.widths[vcd.code(n)] for n in ('engine_busy','engine_bytes_remain','m_axi_bready','sticky_done','sticky_err','irq')):
        raise ValueError('Reset did not clear the selected state on the sampling edge')
    writes = vcd.handshakes('m_axi_wvalid','m_axi_wready')
    responses = vcd.handshakes('m_axi_bvalid','m_axi_bready')
    last_write = max(t for t in writes if t < reset)
    recovery_b = [t for t in responses if restart < t < done]
    if len(recovery_b) != 4 or vcd.value('engine_bytes_remain',restart) != format(16,'032b'):
        raise ValueError('Expected the four-word recovery transfer')
    if vcd.value('engine_bytes_remain',done) != '0'*32:
        raise ValueError('Recovery did not finish all bytes')
    return {'reset_ns':vcd.ns(reset),'clear_ns':vcd.ns(cleared),'release_ns':vcd.ns(release),
            'last_write_ns':vcd.ns(last_write),'restart_ns':vcd.ns(restart),
            'done_ns':vcd.ns(done),'irq_ns':vcd.ns(irq),
            'recovery_b_ns':[vcd.ns(t) for t in recovery_b],
            'committed_word':'0x'+format(int(vcd.value('m_axi_wdata',last_write,True),2),'08x')}


INK, MUTED, BLUE, TEAL, RED = '#172b4d','#52657c','#2563eb','#0f766e','#b4233b'


def setup_plotting():
    import matplotlib
    matplotlib.use('Agg')
    matplotlib.rcParams.update({'font.family':'DejaVu Sans','font.size':11,'svg.fonttype':'none',
                               'svg.hashsalt':'axi-dma-measured-waveforms','axes.unicode_minus':False})
    import matplotlib.pyplot as plt
    return plt


def panel(ax, vcd, signals, limits, color):
    import numpy as np
    lo,hi = limits
    if not 0 <= lo < hi <= vcd.ns(vcd.end):
        raise ValueError('Plot window extends outside captured VCD time')
    count = len(signals)
    for index,(label,name) in enumerate(signals):
        y = count-index-1
        code = vcd.code(name)
        points = [(lo,vcd.value(name,lo/vcd.scale_ns))]
        points += [(vcd.ns(t),bits) for t,bits in vcd.events[code] if lo < vcd.ns(t) < hi]
        points.append((hi,vcd.value(name,hi/vcd.scale_ns,True)))
        ax.axhline(y, color='#e2e8f0',linewidth=.6,zorder=0)
        if vcd.widths[code] == 1:
            xs = [t for t,_ in points]
            ys = [y+.16+.56*int(b) if b in ('0','1') else np.nan for _,b in points]
            shade = MUTED if name == 'clk' else color
            ax.step(xs,ys,where='post',color=shade,linewidth=1.65)
            ax.fill_between(xs,y+.16,ys,step='post',color=shade,alpha=.055)
            for (left,bits),(right,_) in zip(points,points[1:]):
                if bits not in ('0','1'):
                    ax.plot([left,right],[y+.44]*2,color=MUTED,linestyle=':',linewidth=1)
                    if (right-left)/(hi-lo)>.045:
                        ax.text((left+right)/2,y+.45,bits.upper(),ha='center',va='center',fontsize=8,color=MUTED)
        else:
            for (left,bits),(right,_) in zip(points,points[1:]):
                ax.plot([left,right],[y+.3]*2,color=color,linewidth=1)
                ax.plot([left,right],[y+.67]*2,color=color,linewidth=1)
                ax.plot([left,left],[y+.3,y+.67],color=color,linewidth=.8)
                if (right-left)/(hi-lo)>.04:
                    value = str(int(bits,2)) if set(bits)<=set('01') else 'X'
                    ax.text((left+right)/2,y+.485,value,ha='center',va='center',fontsize=9,color=INK)
    ax.set_xlim(lo,hi)
    ax.set_ylim(-.3,count+.1)
    ax.set_yticks([count-i-.56 for i in range(count)])
    ax.set_yticklabels([label for label,_ in signals],fontsize=10,color=INK)
    ax.tick_params(axis='y',length=0,pad=8)
    ax.tick_params(axis='x',labelsize=9,colors=MUTED)
    ax.xaxis.set_major_locator(__import__('matplotlib').ticker.MaxNLocator(6))
    ax.set_xlabel('Simulation time (ns)',color=MUTED,fontsize=10,labelpad=10)
    ax.grid(axis='x',color='#e2e8f0',linewidth=.6)
    for spine in ax.spines.values():
        spine.set_visible(False)


def mark(ax, time, label, color, lane=0):
    ax.axvline(time,color=color,linewidth=1,linestyle='--',alpha=.65)
    ax.text(time,1.035+lane*.06,label,transform=ax.get_xaxis_transform(),ha='center',va='bottom',
            fontsize=9,color=color,bbox={'facecolor':'white','edgecolor':'none','pad':2})


def save(fig, output, name):
    output.mkdir(parents=True,exist_ok=True)
    fig.savefig(output/(name+'.svg'),facecolor='white',metadata={'Date':None,'Creator':'AXI DMA measured waveform renderer'})
    fig.savefig(output/(name+'.png'),dpi=140,facecolor='white')


def render_aw(plt, before, after, output):
    original,fixed = aw_events(before),aw_events(after)
    if any(original.values()) or any(len(fixed[c])!=1 for c in fixed) or not fixed['w'][0]<fixed['aw'][0]<fixed['b'][0]:
        raise ValueError('AW/W traces do not show the expected blocked/fixed behavior')
    done_edges = after.edges('done')
    if not done_edges or before.edges('done'):
        raise ValueError('Invalid DONE evidence')
    stop = before.ns(before.end)
    if stop < 1060 or any(before.value('axi.'+name,before.end)!='1' for name in ('awvalid','wready')) or any(before.value('axi.'+name,before.end)!='0' for name in ('awready','wvalid')):
        raise ValueError('Pre-fix trace does not retain the deadlock through watchdog time')
    fig = plt.figure(figsize=(14,7.3))
    fig.text(.035,.95,'AXI write deadlock: before and after the fix',fontsize=20,weight='bold',color=INK)
    fig.text(.035,.906,'Measured VCD traces | same 4-byte copy, same AW_MODE=0 slave, only the engine RTL changes',fontsize=11,color=MUTED)
    signals=[('clk','clk'),('AWVALID','axi.awvalid'),('AWREADY','axi.awready'),('WVALID','axi.wvalid'),('WREADY','axi.wready'),('BVALID','axi.bvalid'),('BREADY','axi.bready'),('DONE','done')]
    done=after.ns(done_edges[0])
    limits=(40,after.ns(after.end))
    for left,vcd,title,color in ((.105,before,'ORIGINAL ENGINE | observed deadlock',RED),(.605,after,'FIXED ENGINE | UNIT_PASS',TEAL)):
        ax=fig.add_axes([left,.275,.355,.49])
        panel(ax,vcd,signals,limits,color)
        fig.text(left-.065,.855,title,fontsize=12,weight='bold',color=color)
        if vcd is before:
            ax.axvspan(before.ns(before.edges('axi.awvalid')[0]),limits[1],color=RED,alpha=.035)
        else:
            mark(ax,fixed['w'][0],'W accepted',BLUE,0)
            mark(ax,fixed['aw'][0],'AW accepted',TEAL,1)
            mark(ax,fixed['b'][0],'B',MUTED,0)
    fig.text(.04,.13,'AWVALID waits for AWREADY; WVALID never rises.\nThe same stalled levels persist through the 1060 ns watchdog.',fontsize=11,color=INK,linespacing=1.5)
    fig.text(.54,.13,f"W is accepted at {fixed['w'][0]:g} ns, AW at {fixed['aw'][0]:g} ns.\nEach VALID retires independently; DONE rises at {done:g} ns.",fontsize=11,color=INK,linespacing=1.5)
    fig.text(.04,.045,'Handshakes are sampled on rising clock edges using pre-edge VALID/READY. Both panels use the same time scale.',fontsize=9,color=MUTED)
    save(fig,output,'axi_write_deadlock')
    plt.close(fig)
    return {'before':original,'after':fixed,'after_done_ns':done,'before_trace_end_ns':stop}


def render_reset(plt, vcd, output):
    event=reset_events(vcd)
    fig=plt.figure(figsize=(14,7.8))
    fig.text(.035,.952,'Reset during a pending write, then recovery',fontsize=20,weight='bold',color=INK)
    fig.text(.035,.909,'Measured UVM reset_mid_transfer_test, seed 7 | fifth reset scenario: waiting for the B response',fontsize=11,color=MUTED)
    signals=[('rst_n','rst_n'),('BUSY','engine_busy'),('WVALID','m_axi_wvalid'),('WREADY','m_axi_wready'),('BVALID','m_axi_bvalid'),('BREADY','m_axi_bready'),('DONE sticky','sticky_done'),('IRQ','irq'),('bytes left','engine_bytes_remain')]
    windows=[(event['reset_ns']-75,event['release_ns']+15),(event['restart_ns']-20,event['irq_ns']+20)]
    for i,(limits,title) in enumerate(zip(windows,['1 | Cancel the outstanding response','2 | Complete a fresh 16-byte transfer'])):
        left=.105+i*.5
        ax=fig.add_axes([left,.275,.355,.50])
        panel(ax,vcd,signals,limits,BLUE if i==0 else TEAL)
        fig.text(left-.065,.855,title,fontsize=12,weight='bold',color=INK)
        if i==0:
            ax.axvspan(event['reset_ns'],event['release_ns'],color=RED,alpha=.055)
            mark(ax,event['last_write_ns'],'W',BLUE)
            mark(ax,event['reset_ns'],'reset asserted',RED,1)
            mark(ax,event['release_ns'],'released',MUTED)
        else:
            for n,t in enumerate(event['recovery_b_ns'],1):
                mark(ax,t,'B'+str(n),TEAL)
            mark(ax,event['irq_ns'],'DONE / IRQ',BLUE,1)
    gap=windows[1][0]-windows[0][1]
    fig.text(.04,.127,f"W commits at {event['last_write_ns']:g} ns; B has not arrived at reset.\nSynchronous reset clears BUSY and pending state at {event['clear_ns']:g} ns.",fontsize=11,color=INK,linespacing=1.5)
    fig.text(.54,.127,f"Four B handshakes retire 16 bytes. DONE / IRQ rise at {event['irq_ns']:g} ns.\nThe independent scoreboard verifies memory retention and recovery.",fontsize=10.5,color=INK,linespacing=1.5)
    fig.text(.04,.045,f'Two labeled windows from one continuous trace; {gap:g} ns omitted between panels. Each panel has its own ns scale.',fontsize=9,color=MUTED)
    save(fig,output,'reset_recovery')
    plt.close(fig)
    return event


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before',type=Path,default=ROOT/'docs/waveforms/axi_write_before.vcd')
    parser.add_argument('--after',type=Path,default=ROOT/'docs/waveforms/axi_write_after.vcd')
    parser.add_argument('--reset',type=Path,default=ROOT/'docs/waveforms/reset_recovery.vcd')
    parser.add_argument('--output',type=Path,default=ROOT/'docs/images')
    parser.add_argument('--events',type=Path,default=ROOT/'docs/results/waveform_events.json')
    args=parser.parse_args()
    before,after,reset=(Vcd(p) for p in (args.before,args.after,args.reset))
    plt=setup_plotting()
    report={'SchemaVersion':1,'Metric':'events_from_measured_vcd','Sampling':'VALID/READY values immediately before each rising clock edge',
            'TraceSha256':{'before':before.digest(),'after':after.digest(),'reset':reset.digest()},
            'WriteComparison':render_aw(plt,before,after,args.output),
            'ResetRecovery':render_reset(plt,reset,args.output)}
    args.events.parent.mkdir(parents=True,exist_ok=True)
    args.events.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,indent=2))


if __name__=='__main__':
    main()
