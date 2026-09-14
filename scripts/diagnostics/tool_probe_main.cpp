#include "Vtool_probe_assertion.h"
#include "verilated.h"
#include "verilated_cov.h"
#include <memory>
int main(int argc, char** argv) {
  const auto context = std::make_unique<VerilatedContext>();
  context->commandArgs(argc, argv);
  const auto top = std::make_unique<Vtool_probe_assertion>(context.get());
  while (!context->gotFinish()) {
    top->eval();
    if (!top->eventsPending()) break;
    context->time(top->nextTimeSlot());
  }
  top->final();
  context->coveragep()->write("coverage.dat");
  return context->gotFinish() ? 0 : 1;
}
