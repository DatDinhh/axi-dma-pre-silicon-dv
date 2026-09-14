"""Focused checks for VCD timing semantics used by the published figures."""
from pathlib import Path
import tempfile
import unittest
from render_waveforms import Vcd

HEADER = '''$timescale 1ps $end
$scope module test $end
$var wire 1 ! clk $end
$var wire 1 r rst_n $end
$var wire 1 v valid $end
$var wire 1 q ready $end
$var reg 4 d data [3:0] $end
$var wire 1 a split [1] $end
$var wire 1 b split [0] $end
$upscope $end
$enddefinitions $end
'''

class VcdTimingTests(unittest.TestCase):
    def parse(self, body, header=HEADER):
        temp=tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        path=Path(temp.name)/'trace.vcd'
        path.write_text(header+body)
        return Vcd(path)

    def test_retiring_valid_at_edge_is_still_a_handshake(self):
        v=self.parse('#0 0! 1r 1v 1q #5000 1! 0v #10000 0!')
        self.assertEqual(v.handshakes('valid','ready'),[5000])
        self.assertEqual(v.value('valid',5000,True),'1')
        self.assertEqual(v.value('valid',5000),'0')
        self.assertEqual(v.ns(5000),5)

    def test_valid_asserted_by_nba_waits_for_next_edge(self):
        v=self.parse('#0 0! 1r 0v 1q #5000 1! 1v #10000 0! #15000 1! 0v')
        self.assertEqual(v.handshakes('valid','ready'),[15000])

    def test_reset_and_unknown_ready_do_not_count(self):
        v=self.parse('#0 0! 0r 1v 1q #5000 1! #10000 0! 1r xq #15000 1!')
        self.assertEqual(v.handshakes('valid','ready'),[])

    def test_same_timestamp_changes_use_final_level(self):
        v=self.parse('#0 0! 1r 0v 1q #5000 1! 1v 0v 1v #10000 0! #15000 1!')
        self.assertEqual(v.value('valid',5000),'1')
        self.assertEqual(v.handshakes('valid','ready'),[15000])

    def test_split_wire_names_and_vector_extension(self):
        v=self.parse('#0 0! 1r 0v 0q 1a 0b bx d #1000 b11 d')
        self.assertEqual(v.value('split[1]',0),'1')
        self.assertEqual(v.value('split[0]',0),'0')
        self.assertEqual(v.value('data',0),'xxxx')
        self.assertEqual(v.value('data',1000),'0011')

    def test_signal_aliases_do_not_create_false_ambiguity(self):
        header=HEADER.replace('$upscope $end','$var wire 1 ! clock_alias $end\n$upscope $end')
        v=self.parse('#0 0! 1r 1v 1q #5000 1!',header)
        self.assertEqual(v.edges('clock_alias'),[5000])

    def test_invalid_time_or_undeclared_signal_is_rejected(self):
        for body in ('#10 0! #5 1!','#0 0UNKNOWN'):
            with self.subTest(body=body),self.assertRaises(ValueError):
                self.parse(body)

    def test_missing_or_ambiguous_signal_is_rejected(self):
        v=self.parse('#0 0!')
        with self.assertRaises(ValueError):
            v.code('does_not_exist')
        header=HEADER.replace('$enddefinitions $end','$scope module other $end\n$var wire 1 c clk $end\n$upscope $end\n$enddefinitions $end')
        v=self.parse('#0 0! 0c',header)
        with self.assertRaises(ValueError):
            v.code('clk')

if __name__=='__main__':
    unittest.main()
