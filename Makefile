# Makefile - wygodne skróty do typowych poleceń projektu.
#
# Cele Nix wymagają włączonych flag (nix-command, flakes).  Jeśli nie masz ich
# w konfiguracji globalnej, każde polecenie nix uruchamiane jest z odpowiednią
# flagą poprzez zmienną NIX_FLAGS poniżej.

SYSTEM     ?= x86_64-linux
HOSTS      := gateway www cache db
IMG_DIR    ?= ./images
NIX_FLAGS  ?= --extra-experimental-features "nix-command flakes"
NIXC       := nix $(NIX_FLAGS)

# Pozwala wywołać np. `make console www` bez ostrzeżeń o nieznanym celu.
HOST_ARG   := $(filter-out $@,$(MAKECMDGOALS))

.DEFAULT_GOAL := help
.PHONY: help check test images $(addprefix image-,$(HOSTS)) \
        up down status console deploy report fmt clean clean-report $(HOSTS)

## help: wyświetl tę pomoc
help:
	@echo "Dostępne cele:"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /'
	@echo ""
	@echo "Przykłady:"
	@echo "  make test                 # test integracyjny w QEMU"
	@echo "  make images               # zbuduj obrazy qcow2 wszystkich hostów"
	@echo "  make image-www            # zbuduj obraz jednej maszyny"
	@echo "  sudo -E make up           # postaw klaster na libvirt (IMG_DIR=...)"
	@echo "  make console www          # konsola szeregowa maszyny www"
	@echo "  make deploy HOST=www IP=10.10.0.10   # nixos-rebuild na zdalny host"
	@echo "  make report               # zbuduj raport PDF"

## check: uruchom wszystkie testy flake (nix flake check)
check:
	$(NIXC) flake check -L

## test: uruchom sam test integracyjny (ICMP + nmap)
test:
	$(NIXC) build .#checks.$(SYSTEM).integration -L

## images: zbuduj obrazy qcow2 wszystkich maszyn do katalogu $(IMG_DIR)
images: $(addprefix image-,$(HOSTS))

## image-<host>: zbuduj obraz qcow2 jednej maszyny (gateway|www|cache|db)
image-%:
	@mkdir -p $(IMG_DIR)
	$(NIXC) build .#image-$* -o result-image-$*
	@cp -L result-image-$*/nixos.qcow2 $(IMG_DIR)/$*.qcow2
	@echo "  -> $(IMG_DIR)/$*.qcow2"

## up: postaw sieci i maszyny na hoście libvirt (wymaga uprawnień: sudo -E)
up:
	IMG_DIR=$(IMG_DIR) $(NIXC) run .#vmctl -- up

## down: usuń maszyny i sieci z hosta libvirt
down:
	$(NIXC) run .#vmctl -- down

## status: pokaż stan sieci i domen libvirt
status:
	$(NIXC) run .#vmctl -- status

## console: podłącz się do konsoli maszyny, np. `make console www`
console:
	$(NIXC) run .#vmctl -- console $(HOST_ARG)

## deploy: wdroż konfigurację na zdalny host (HOST=<rola> IP=<adres>)
deploy:
	@test -n "$(HOST)" || { echo "podaj HOST=<gateway|www|cache|db>"; exit 1; }
	@test -n "$(IP)"   || { echo "podaj IP=<adres hosta>"; exit 1; }
	nixos-rebuild switch --flake .#$(HOST) --target-host root@$(IP)

## report: zbuduj raport PDF (report/raport.pdf)
report:
	cd report && latexmk -pdf -interaction=nonstopmode -halt-on-error raport.tex

## fmt: sformatuj pliki Nix (nixpkgs-fmt)
fmt:
	$(NIXC) fmt

## clean: usuń artefakty budowania (result*, obrazy, pliki pomocnicze LaTeX)
clean: clean-report
	rm -rf result result-* $(IMG_DIR)

## clean-report: usuń pliki pomocnicze LaTeX (zostawia PDF)
clean-report:
	cd report && rm -f *.aux *.log *.toc *.out *.synctex.gz *.fls *.fdb_latexmk

# Pozwala przekazać nazwę hosta jako argument (np. `make console www`) bez
# traktowania jej jako osobnego celu.
$(HOSTS):
	@:
