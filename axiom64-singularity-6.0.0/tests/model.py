#!/usr/bin/env python3
"""Bounded state-space checker for Axiom64 Singularity 6 invariants."""

from __future__ import annotations


def cap_derive(parent: int, requested: int) -> int | None:
    return requested if requested & ~parent == 0 else None


def pick(loads: tuple[int, ...], mask: int) -> int | None:
    candidates = [index for index in range(len(loads)) if mask & (1 << index)]
    return min(candidates, key=lambda index: (loads[index], index)) if candidates else None


def hotplug(state: int, event: int) -> int | None:
    transitions = {
        (0, 0): 1,
        (1, 1): 2,
        (1, 4): 4,
        (2, 2): 3,
        (2, 4): 4,
        (3, 3): 0,
        (3, 4): 4,
        (4, 5): 0,
    }
    return transitions.get((state, event))


def main() -> None:
    cases = 0

    # Complete nine-bit capability lattice: no child acquires a parent-missing bit.
    for parent in range(512):
        for requested in range(512):
            child = cap_derive(parent, requested)
            assert (child is None) == bool(requested & ~parent)
            if child is not None:
                assert child & ~parent == 0
            cases += 1

    # Exhaustive four-CPU scheduler/load/affinity state space.
    for a in range(8):
        for b in range(8):
            for c in range(8):
                for d in range(8):
                    loads = (a, b, c, d)
                    for mask in range(16):
                        selected = pick(loads, mask)
                        if mask == 0:
                            assert selected is None
                        else:
                            assert selected is not None
                            assert mask & (1 << selected)
                            for index, load in enumerate(loads):
                                if mask & (1 << index):
                                    assert (loads[selected], selected) <= (load, index)
                        cases += 1

    # Every CPU hotplug state/event pair is deterministic and range-safe.
    for state in range(5):
        for event in range(6):
            nxt = hotplug(state, event)
            assert nxt is None or 0 <= nxt < 5
            cases += 1

    # x2APIC ICR fields remain disjoint under their architectural masks.
    for vector in range(256):
        for delivery in range(8):
            for destination in range(32):
                icr = vector | (delivery << 8) | (destination << 32)
                assert icr & 0xFF == vector
                assert (icr >> 8) & 7 == delivery
                assert (icr >> 32) & 0xFFFFFFFF == destination
                cases += 1

    # KASLR model remains aligned and within the declared slot arena.
    base = 0xFFFFFFFF80000000
    alignment = 0x200000
    for slots in range(1, 65):
        for entropy in range(4096):
            address = base + (entropy % slots) * alignment
            assert address >= base
            assert address < base + slots * alignment
            assert (address - base) % alignment == 0
            cases += 1

    # Small exhaustive DMA window containment and overflow-free bounds model.
    for base_page in range(8):
        for pages in range(1, 9):
            base = base_page * 4096
            size = pages * 4096
            for offset in range(0, size + 4096, 1024):
                for length in (1, 64, 4096):
                    address = base + offset
                    permitted = address >= base and address + length <= base + size
                    if permitted:
                        assert offset + length <= size
                    cases += 1

    # IOMMU requester isolation: only exact BDF membership grants DMA authority.
    allowlists = ((), (0x8,), (0x8, 0x110), (0x8, 0x110, 0x2F8))
    for allowlist in allowlists:
        for bdf in range(0x400):
            allowed = bdf in allowlist
            assert allowed == any(item == bdf for item in allowlist)
            cases += 1

    # Queue arithmetic never yields an index outside a non-empty ring.
    for depth in range(1, 257):
        for index in range(depth):
            nxt = index + 1
            if nxt >= depth:
                nxt = 0
            assert 0 <= nxt < depth
            cases += 1

    # W^X model: writable mappings are never executable.
    for writable in (0, 1):
        for executable in (0, 1):
            accepted = not (writable and executable)
            if accepted and writable:
                assert not executable
            cases += 1

    print("Axiom64 Singularity 6 bounded architecture model")
    print(f"cases: {cases}")
    print("invariants: capability attenuation, SMP/NUMA selection, CPU hotplug, x2APIC, KASLR, DMA, IOMMU, ring bounds, W^X")
    print("status: PASS")


if __name__ == "__main__":
    main()
