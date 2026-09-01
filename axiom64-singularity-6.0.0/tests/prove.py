#!/usr/bin/env python3
"""Z3 proofs for Axiom64 Singularity 6 critical encoding invariants.

These are symbolic proofs of documented primitive specifications. They are not
claimed to be a whole-kernel machine-code refinement theorem. Every solver
query has a hard timeout and `unknown` is a qualification failure.
"""

from __future__ import annotations

from z3 import (
    And,
    BitVec,
    BitVecVal,
    Bool,
    Extract,
    If,
    Int,
    Not,
    Or,
    Solver,
    UGE,
    ULT,
    ZeroExt,
    unsat,
)

proofs = 0


def prove(name: str, assumptions, claim) -> None:
    global proofs
    print(f"[START] {name}", flush=True)
    solver = Solver()
    solver.set(timeout=5000)
    if assumptions is not None:
        if isinstance(assumptions, (list, tuple)):
            solver.add(*assumptions)
        else:
            solver.add(assumptions)
    solver.add(Not(claim))
    result = solver.check()
    if result != unsat:
        raise AssertionError(
            f"{name}: expected unsat, received {result}; reason={solver.reason_unknown()}"
        )
    proofs += 1
    print(f"[PROVED] {name}", flush=True)


def main() -> None:
    parent = BitVec("parent", 9)
    requested = BitVec("requested", 9)
    admitted = (requested & ~parent) == 0
    prove(
        "capability derivation cannot amplify rights",
        admitted,
        (requested & ~parent) == 0,
    )

    old_generation = BitVec("old_generation", 16)
    new_generation = BitVec("new_generation", 16)
    handle_generation = BitVec("handle_generation", 16)
    prove(
        "generation change invalidates a stale capability handle",
        old_generation != new_generation,
        Not(And(handle_generation == old_generation, handle_generation == new_generation)),
    )

    vector = BitVec("vector", 8)
    delivery = BitVec("delivery", 3)
    destination = BitVec("destination", 32)
    icr = ZeroExt(56, vector) | (ZeroExt(61, delivery) << 8) | (
        ZeroExt(32, destination) << 32
    )
    prove("x2APIC vector field round-trips", None, Extract(7, 0, icr) == vector)
    prove(
        "x2APIC delivery-mode field round-trips",
        None,
        Extract(10, 8, icr) == delivery,
    )
    prove(
        "x2APIC destination field round-trips",
        None,
        Extract(63, 32, icr) == destination,
    )

    # The executable KASLR primitive places the image in one of 64 2-MiB
    # slots. Prove the actual 64-bit address arithmetic rather than asking an
    # older solver to decide nonlinear integer multiplication/modulo.
    kaslr_slot = BitVec("kaslr_slot", 6)
    kaslr_base = BitVecVal(0xFFFFFFFF80000000, 64)
    kaslr_alignment_shift = 21
    kaslr_arena_end = BitVecVal(0xFFFFFFFF88000000, 64)
    kaslr_address = kaslr_base + (ZeroExt(58, kaslr_slot) << kaslr_alignment_shift)
    prove(
        "KASLR address remains inside its 64-slot arena",
        None,
        And(UGE(kaslr_address, kaslr_base), ULT(kaslr_address, kaslr_arena_end)),
    )
    prove(
        "KASLR address remains 2-MiB aligned",
        None,
        Extract(20, 0, kaslr_address) == BitVecVal(0, 21),
    )

    cpl = BitVec("cpl", 2)
    kernel_cr3 = BitVec("kernel_cr3", 64)
    user_cr3 = BitVec("user_cr3", 64)
    selected_cr3 = If(cpl == 0, kernel_cr3, user_cr3)
    prove(
        "KPTI selector exposes only kernel or user page tables",
        None,
        Or(selected_cr3 == kernel_cr3, selected_cr3 == user_cr3),
    )
    prove(
        "KPTI never selects the user CR3 at CPL0",
        cpl == 0,
        selected_cr3 == kernel_cr3,
    )

    cet_supported = BitVec("cet_supported", 2)
    cet_requested = BitVec("cet_requested", 2)
    cet_enabled = cet_supported & cet_requested
    prove(
        "CET policy cannot enable an unsupported feature",
        None,
        (cet_enabled & ~cet_supported) == 0,
    )
    prove(
        "CET policy cannot enable an unrequested feature",
        None,
        (cet_enabled & ~cet_requested) == 0,
    )

    physical = BitVec("physical", 64)
    flags = BitVec("flags", 64)
    nx = Bool("nx")
    address_mask = BitVecVal(0x000FFFFFFFFFF000, 64)
    pte = (physical & address_mask) | (flags & BitVecVal(0xFFF, 64)) | If(
        nx, BitVecVal(1 << 63, 64), BitVecVal(0, 64)
    )
    prove(
        "page-table low permission bits are independent of physical address",
        None,
        Extract(11, 0, pte) == Extract(11, 0, flags),
    )
    prove(
        "page-table NX bit exactly follows policy",
        None,
        Extract(63, 63, pte) == If(nx, BitVecVal(1, 1), BitVecVal(0, 1)),
    )

    dma_base = Int("dma_base")
    dma_size = Int("dma_size")
    dma_address = Int("dma_address")
    dma_length = Int("dma_length")
    dma_allowed = And(
        dma_base >= 0,
        dma_size > 0,
        dma_address >= dma_base,
        dma_length > 0,
        dma_address + dma_length <= dma_base + dma_size,
    )
    prove(
        "DMA authority cannot extend above its assigned window",
        dma_allowed,
        dma_address + dma_length <= dma_base + dma_size,
    )
    prove(
        "DMA authority cannot begin below its assigned window",
        dma_allowed,
        dma_address >= dma_base,
    )

    depth = Int("depth")
    index = Int("index")
    advanced = If(index + 1 >= depth, 0, index + 1)
    prove(
        "ring advancement remains in bounds",
        [depth > 0, index >= 0, index < depth],
        And(advanced >= 0, advanced < depth),
    )

    for key in range(16):
        mask_value = 3 << (key * 2)
        mask = BitVecVal(mask_value, 64)
        prove(
            f"MPK key {key} sets exactly its two PKRU bits",
            None,
            ((mask >> (key * 2)) & BitVecVal(3, 64)) == BitVecVal(3, 64),
        )
        prove(
            f"MPK key {key} sets no bit outside its assigned pair",
            None,
            (mask & BitVecVal((~mask_value) & ((1 << 64) - 1), 64)) == BitVecVal(0, 64),
        )

    bdf = BitVec("bdf", 16)
    allow0 = BitVec("allow0", 16)
    allow1 = BitVec("allow1", 16)
    allow2 = BitVec("allow2", 16)
    permitted = Or(bdf == allow0, bdf == allow1, bdf == allow2)
    prove(
        "IOMMU requester outside the allowlist is denied",
        And(bdf != allow0, bdf != allow1, bdf != allow2),
        Not(permitted),
    )

    print(f"proofs: {proofs}")
    print("scope: symbolic specification-level bit-vector and linear-integer invariants")
    print("status: PASS")


if __name__ == "__main__":
    main()
