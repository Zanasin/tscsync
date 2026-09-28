# SPDX-License-Identifier: MIT
# Builds build/tscsync.efi (unsigned) and the Linux-side tools.
# gnu-efi is downloaded at a pinned version, checksum-verified and built
# locally under build/; nothing is installed system-wide.

GNUEFI_VERSION := 4.0.2
GNUEFI_SHA256  := f31488c3fc7d64257ec8fcad470ec75a936a4db77350fabaf043c52a7acbae72
GNUEFI_URL     := https://github.com/ncroxon/gnu-efi/archive/refs/tags/$(GNUEFI_VERSION).tar.gz

B       := build
GNUEFI  := $(CURDIR)/$(B)/gnu-efi-$(GNUEFI_VERSION)
ARCHDIR := $(GNUEFI)/x86_64
LIBEFI  := $(ARCHDIR)/lib/libefi.a

CFLAGS_EFI := -I$(GNUEFI)/inc -I$(GNUEFI)/inc/x86_64 -I$(GNUEFI)/inc/protocol \
	-DCONFIG_x86_64 -DGNU_EFI_USE_MS_ABI -std=c11 -maccumulate-outgoing-args \
	-mno-red-zone -mno-avx -mgeneral-regs-only -fPIC -fPIE -O2 -Wall -Wextra -Werror \
	-fno-strict-aliasing -ffreestanding -fno-stack-protector -fno-merge-all-constants \
	-fshort-wchar

LDFLAGS_EFI := -nostdlib --warn-common --no-undefined --fatal-warnings --build-id=sha1 \
	-z norelro -z nocombreloc -pie -Bsymbolic --no-dynamic-linker \
	-L$(ARCHDIR)/lib -L$(ARCHDIR)/gnuefi -T $(GNUEFI)/gnuefi/elf_x86_64_efi.lds

EFI_SECTIONS := -j .text -j .sdata -j .data -j .dynamic -j .rodata -j .rel \
	-j .rela -j .rel.* -j .rela.* -j .rel* -j .rela* -j .areloc -j .reloc

# tscsync.efi: GRUB application; tscsync-driver.efi: systemd-boot driver (same code)
all: $(B)/tscsync.efi $(B)/tscsync-driver.efi $(B)/tscprobe

# VM-only test build: deliberately desyncs cores before syncing them.
test: $(B)/tscsync-test.efi $(B)/tscsync-test-driver.efi

$(B)/gnu-efi.tar.gz:
	mkdir -p $(B)
	curl -fsSL -o $@.tmp $(GNUEFI_URL)
	echo "$(GNUEFI_SHA256)  $@.tmp" | sha256sum -c -
	mv $@.tmp $@

$(LIBEFI): $(B)/gnu-efi.tar.gz
	tar -xzf $< -C $(B)
	$(MAKE) -C $(GNUEFI) ARCH=x86_64 lib gnuefi

$(B)/%.o: src/tscsync.c $(LIBEFI)
	gcc $(CFLAGS_EFI) $(if $(findstring test,$*),-DTSCSYNC_TEST) -c $< -o $@

$(B)/%.so: $(B)/%.o
	ld $(LDFLAGS_EFI) $(ARCHDIR)/gnuefi/crt0-efi-x86_64.o $< -o $@ -lefi -lgnuefi \
		$(shell gcc -print-libgcc-file-name)

$(B)/%.efi: $(B)/%.so
	objcopy $(EFI_SECTIONS) -O efi-app-x86_64 --subsystem=10 $< $@

# Boot-services driver: systemd-boot only starts drivers from EFI/systemd/drivers.
$(B)/%-driver.efi: $(B)/%.so
	objcopy $(EFI_SECTIONS) -O efi-bsdrv-x86_64 --subsystem=11 $< $@

$(B)/tscprobe: tools/tscprobe.c
	mkdir -p $(B)
	gcc -O2 -Wall -Wextra -pthread -o $@ $<

clean:
	rm -f $(B)/*.o $(B)/*.so $(B)/*.efi $(B)/tscprobe

distclean:
	rm -rf $(B)

.PHONY: all test clean distclean
.SECONDARY:
