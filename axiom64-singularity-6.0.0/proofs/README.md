# Proof Scope

`tests/prove.py` uses Z3 to prove specification-level invariants for:

- capability rights attenuation;
- stale-handle invalidation after generation change;
- x2APIC ICR field separation;
- KASLR slot bounds and alignment;
- KPTI CR3 selection;
- CET requested/supported intersection;
- page-table physical/permission/NX separation;
- DMA window bounds;
- queue index bounds;
- MPK bit placement;
- IOMMU requester allowlist denial.

The formulas are universally quantified by proving the negation unsatisfiable. They model the documented primitive semantics. They do not constitute a refinement proof from every emitted machine instruction to a complete abstract operating-system model.

The release certificate therefore reports symbolic proofs as PASS while reporting a whole-kernel machine-code refinement theorem as **NOT CLAIMED**.
