/*! Default driver for Kôika programs compiled to C++ using Verilator !*/
#include "verilator.hpp"
#include "Vmkfir.h"

class TB : public KoikaToplevel<Vmkfir> {
  using KoikaToplevel<Vmkfir>::dut;

public:
  void run(uint64_t ncycles) {
    KoikaToplevel<Vmkfir>::run(ncycles);
    printf("%d", dut.rd);
  }

  TB() : KoikaToplevel<Vmkfir>{} {}
};

int main(int argc, char** argv) {
  return _main<TB>(argc, argv);
}

// Local Variables:
// flycheck-clang-include-path: ("/usr/share/verilator/include" "/usr/share/verilator/include/vltstd/" "Vobj_dir/trace/" "VmkCombinationalFFT.obj_dir.opt/")
// End:
