{ pkgs
, diskImageSize ? "70G"
, windowsImage ? null
, autoUnattendParams ? {}
, impureMode ? false
, installCommands ? []
, users ? {}
# autounattend always installs index 1, so this default is backward-compatible
, imageSelection ? "1"
, efi ? true
, ...
}@attrs:

let
  lib = pkgs.lib;
  utils = import ./utils.nix { inherit pkgs efi; };
  libguestfs = pkgs.libguestfs-with-appliance;

  # p7zip on >20.03 has known vulns but we have no better option
  p7zip = pkgs.p7zip.overrideAttrs(old: {
    meta = old.meta // {
      knownVulnerabilities = [];
    };
  });

  runQemuCommand = name: command: (
    pkgs.runCommandNoCC name { buildInputs = [ p7zip utils.qemu libguestfs ]; }
      (
        ''
          if ! test -f; then
            echo "KVM not available, bailing out" >> /dev/stderr
            exit 1
          fi
        '' + command
      )
  );

  windowsIso = if windowsImage != null then windowsImage else pkgs.fetchurl {
    name = "RESTRICTDIST-release_svc_refresh_CLIENT_LTSC_EVAL_x64FRE_en-us.iso";
    url = "https://software-download.microsoft.com/download/sg/17763.107.101029-1455.rs5_release_svc_refresh_CLIENT_LTSC_EVAL_x64FRE_en-us.iso";
    sha256 = "668fe1af70c2f7416328aee3a0bb066b12dc6bbd2576f40f812b95741e18bc3a";
  };

  # stable as of 2021-04-08
  virtioWinIso = pkgs.fetchurl {
    url = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.185-2/virtio-win-0.1.185.iso";
    sha256 = "11n3kjyawiwacmi3jmfmn311g9xvfn6m0ccdwnjxw1brzb4kqaxg";
  };

  openSshServerPackage = ./openssh/server-package.cab;

  autounattend = import ./autounattend.nix (
    attrs // {
      inherit pkgs;
      users = users // {
        wfvm = {
          password = "1234";
          description = "WFVM Administrator";
          groups = [
            "Administrators"
          ];
        };
      };
    }
  );

  bundleInstaller = pkgs.callPackage ./bundle {};

  # Packages required to drive installation of other packages
  bootstrapPkgs =
    runQemuCommand "bootstrap-win-pkgs.img" ''
      mkdir -p pkgs/fod

      7z x -y ${virtioWinIso} -opkgs/virtio

      cp ${bundleInstaller} pkgs/"$(stripHash "${bundleInstaller}")"

      # Install optional windows features
      cp ${openSshServerPackage} pkgs/fod/OpenSSH-Server-Package~31bf3856ad364e35~amd64~~.cab

      # SSH setup script goes here because windows XML parser sucks
      cp ${autounattend.setupScript} pkgs/ssh-setup.ps1

      virt-make-fs --partition --type=fat pkgs/ $out
    '';

  installScript = pkgs.writeScript "windows-install-script" (
    let
      qemuParams = utils.mkQemuFlags (lib.optional (!impureMode) "-display none" ++ [
        # "CD" drive with bootstrap pkgs
        "-drive"
        "id=virtio-win,file=${bootstrapPkgs},if=none,format=raw,readonly=on"
        "-device"
        "usb-storage,drive=virtio-win"
        # USB boot
        "-drive"
        "id=win-install,file=${if efi then "usb" else "cd"}image.img,if=none,format=raw,readonly=on,media=${if efi then "disk" else "cdrom"}"
        "-device"
        "usb-storage,drive=win-install"
        # Output image
        "-drive"
        "file=c.img,index=0,media=disk,if=virtio,cache=unsafe"
        # Network
        "-netdev user,id=n1,net=192.168.1.0/24,restrict=on"
      ]);
    in
      ''
        #!${pkgs.runtimeShell}
        set -euxo pipefail
        export PATH=${lib.makeBinPath [ p7zip utils.qemu libguestfs pkgs.wimlib ]}:$PATH

        # Create a bootable "USB" image
        # Booting in USB mode circumvents the "press any key to boot from cdrom" prompt
        #
        # Also embed the autounattend answer file in this image
        mkdir -p win
        mkdir -p win/nix-win
        7z x -y ${windowsIso} -owin

        # Extract desired variant from install.wim
        # This is useful if the install.wim contains multiple Windows
        # versions (e.g., Home, Pro, ..), because the autounattend file
        # will always select index 1. With this mechanism, a variant different
        # from the first one can be automatically selected.
        # imageSelection can be either an index (1-N) or the image name
        # wiminfo can list all images contained in a given WIM file
        wimexport win/sources/install.wim "${imageSelection}" win/sources/install_selected.wim
        rm win/sources/install.wim

        # Split image so it fits in FAT32 partition
        wimsplit win/sources/install_selected.wim win/sources/install.swm 4096
        rm win/sources/install_selected.wim

        cp ${autounattend.autounattendXML} win/autounattend.xml

        ${if efi then ''
        virt-make-fs --partition --type=fat win/ usbimage.img
        '' else ''
        ${pkgs.cdrkit}/bin/mkisofs -iso-level 4 -l -R -udf -D -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -hide boot.catalog -eltorito-alt-boot -o cdimage.img win/
        ''}
        rm -rf win

        # Qemu requires files to be rw
        qemu-img create -f qcow2 c.img ${diskImageSize}
        qemu-system-x86_64 ${lib.concatStringsSep " " qemuParams}
      ''
  );

  baseImage = pkgs.runCommandNoCC "RESTRICTDIST-windows.img" {} ''
    ${installScript}
    mv c.img $out
  '';

  finalImage = builtins.foldl' (acc: v: pkgs.runCommandNoCC "RESTRICTDIST-${v.name}.img" {
    buildInputs = with utils; [
      qemu win-wait win-exec win-put
    ] ++ (v.buildInputs or []);
  } (let
    script = pkgs.writeScript "${v.name}-script" v.script;
    qemuParams = utils.mkQemuFlags (lib.optional (!impureMode) "-display none" ++ [
      # Output image
      "-drive"
      "file=c.img,index=0,media=disk,if=virtio,cache=unsafe"
      # Network - enable SSH forwarding
      "-netdev user,id=n1,net=192.168.1.0/24,restrict=on,hostfwd=tcp::2022-:22"
    ]);

  in ''
    # Create an image referencing the previous image in the chain
    qemu-img create -f qcow2 -b ${acc} c.img

    set -m
    qemu-system-x86_64 ${lib.concatStringsSep " " qemuParams} &

    win-wait

    echo "Executing script to build layer..."
    ${script}
    echo "Layer script done"

    echo "Shutting down..."
    win-exec 'shutdown /s'
    echo "Waiting for VM to terminate..."
    fg
    echo "Done"

    mv c.img $out
  '')) baseImage (
    [
      {
        name = "DisablePasswordExpiry";
        script = ''
          win-exec 'wmic UserAccount set PasswordExpires=False'
        '';
      }
    ] ++
    installCommands
  );

in

# impureMode is meant for debugging the base image, not the full incremental build process
if !(impureMode) then finalImage else assert installCommands == []; installScript
