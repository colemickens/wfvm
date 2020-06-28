![XBill](xbill.png)

WFVM
====

A Nix library to create and manage virtual machines running Windows, a medieval operating system found on most computers in 2020. The F stands for "Functional" or a four-letter word of your choice.

* Reproducible - everything runs in the Nix sandbox with no tricks.
* Fully automatic, parameterizable Windows 10 installation.
* Uses QEMU with KVM.
* Supports incremental installation (using "layers") of additional software via QEMU copy-on-write backing chains.
* Included layers: Anaconda3, a software installer chock full of bugs that pretends to be a package manager, Visual Studio, a spamming system for Microsoft accounts that includes a compiler, and MSYS2, which is the only sane component in the whole lot.
* Supports running arbitrary commands in a VM image in snapshot mode inside a derivation and retrieve the result.
* Network access from the VM is heavily restricted to avoid issues with Microsoft spyware and similar programs.
* When used with Hydra, redistribution of nonfree content can be blocked.

Example applications:
* Creating reproducible Windows VM images with pre-installed software.
* Compiling Conda packages with Visual Studio in a fully reproducible manner and without having to deal with the constant data corruption caused by Conda.
* Running Windows unit tests on Hydra.