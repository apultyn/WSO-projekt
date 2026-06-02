# Deklaratywne zarządzanie maszynami wirtualnymi i ich sieciami na NixOS

Projekt na przedmiot **WSO 2026L** — *Zarządzanie maszynami wirtualnymi i
sieciami je łączącymi na systemie NixOS z wykorzystaniem języka Nix.*

Autorzy: **Filip Kobierski (348591)**, **Andrzej Pultyn (325213)**

Repozytorium zawiera zestaw wyrażeń Nix oraz skryptów, które **tworzą, wdrażają,
filtrują i usuwają** niewielki klaster maszyn wirtualnych wraz z sieciami je
łączącymi. Realizuje scenariusz z koncepcji — trójwarstwową usługę WWW
(serwer WWW → pamięć podręczna → baza danych) wdrożoną jako **łańcuch maszyn**
(*daisy chain*) — z osobną zaporą dla każdej warstwy, NAT-em na brzegu sieci
oraz zautomatyzowanym testem potwierdzającym, że segmentacja sieci faktycznie
działa.

---

## 1. Co robi projekt

* Opisuje cały klaster — maszyny, segmenty L2 między nimi, adresację, routing,
  NAT i reguły zapory — jako **jeden model deklaratywny** w pliku
  [`lib/topology.nix`](lib/topology.nix). Wszystko pozostałe jest z niego
  wyprowadzane.
* Buduje każdą maszynę jako system NixOS / gotowy do uruchomienia obraz
  `qcow2` (`nix build`).
* Tworzy i usuwa **sieci** oraz **domeny** libvirt jednym poleceniem
  ([`scripts/vmctl.sh`](scripts/vmctl.sh)).
* Filtruje ruch jawnymi, audytowalnymi regułami **nftables** generowanymi dla
  każdej roli ([`lib/firewall.nix`](lib/firewall.nix)): polityka
  *default-deny*, zasada najmniejszych uprawnień, NAT tylko na brzegu, brak
  ruchu wychodzącego z bazy danych.
* Automatycznie weryfikuje właściwości bezpieczeństwa **testem integracyjnym
  NixOS** ([`tests/integration.nix`](tests/integration.nix)), realizującym
  plan testów z koncepcji (widoczność ICMP + skan portów `nmap`).

## 2. Architektura

```
  Internet         sieć edge          sieć app           sieć data
(client)  ──┐    10.10.0.0/24      10.20.0.0/24       10.30.0.0/24
192.0.2.10  │   ┌─────────┐      ┌─────────┐      ┌─────────┐      ┌──────┐
            └──▶│ gateway │─edge─│   www   │─app──│  cache  │─data─│  db  │
   192.0.2.1    │  NAT/FW │      │  nginx  │      │  redis  │      │ pgsql│
                └─────────┘      └─────────┘      └─────────┘      └──────┘
   DNAT :80/443 → www       www→cache:6379    cache→db:5432   db: brak egress
```

Każde połączenie między warstwami stanowi **osobny segment warstwy 2**. Nie ma
wspólnej domeny rozgłoszeniowej, więc warstwa może dosięgnąć innej tylko wtedy,
gdy jest fizycznie podłączona do tego samego segmentu *oraz* zapora po drugiej
stronie na to zezwala. Łańcuch może w przyszłości rozrosnąć się w drzewo (np.
o drugą, ściślej izolowaną bazę danych) przez dodanie hostów i segmentów do
modelu topologii — nic poza tym nie wymaga zmiany.

### Adresacja i macierz dostępu

| segment | CIDR          | uczestnicy (adres)                  |
|---------|---------------|-------------------------------------|
| wan     | 192.0.2.0/24  | gateway `.1`, client `.10` (test)   |
| edge    | 10.10.0.0/24  | gateway `.1`, www `.10`             |
| app     | 10.20.0.0/24  | www `.1`, cache `.10`              |
| data    | 10.30.0.0/24  | cache `.1`, db `.10`              |

| źródło          | cel            | port      | uzasadnienie                |
|-----------------|----------------|-----------|-----------------------------|
| Internet        | gateway (publ.)| 80, 443   | opublikowany serwis (DNAT → www) |
| www             | cache          | 6379      | dostęp do Redis             |
| cache           | db             | 5432      | dostęp do PostgreSQL        |
| zakres admin.   | każdy host     | 22        | zarządzanie (SSH)           |
| *pozostałe*     | —              | —         | **odrzucane**               |

Baza danych ma dodatkowo politykę **default-deny na ruchu wychodzącym**: nawet
po przejęciu nie nawiąże połączenia na zewnątrz. Warstwy cache i db **nie mają
trasy domyślnej**, więc w ogóle nie są w stanie połączyć się z Internetem.

## 3. Struktura repozytorium

```
flake.nix                 punkt wejścia: systemy, obrazy, testy, vmctl, devShell
Makefile                  skróty do typowych poleceń (make help)
lib/
  topology.nix            jedno źródło prawdy (sieci, hosty, porty, adresy)
  mkHost.nix              wpis topologii  -> kompletny moduł NixOS (sieć+zapora+rola)
  firewall.nix            rola            -> kompletny zestaw reguł nftables
modules/
  common.nix              bazowe twardnienie każdej VM (SSH, użytkownicy, …)
  libvirt-guest.nix       konfiguracja dysku/rozruchu dla realnych gości libvirt
  roles/{gateway,www,cache,db,client}.nix   usługi poszczególnych ról
tests/
  integration.nix         uruchamia cały łańcuch w QEMU i sonduje go
scripts/
  vmctl.sh                CLI libvirt: tworzenie/usuwanie sieci i maszyn
report/
  raport.tex              raport projektowy (LaTeX) wraz z analizą bezpieczeństwa
```

## 4. Użycie

Najwygodniej przez **Makefile** (`make help` wypisze wszystkie cele). Poniżej
także polecenia w surowej postaci.

### Wymagania wstępne

* Nix z włączonymi flagami (`experimental-features = nix-command flakes`).
* Do realnego wdrożenia: host libvirt/KVM (docelowy serwer NixOS projektu).

### Uruchomienie testu automatycznego (bez libvirt)

```sh
make test            # sam test integracyjny
make check           # wszystkie testy flake
# albo bezpośrednio:
nix build .#checks.x86_64-linux.integration -L
```

Test uruchamia maszyny `gateway`, `www`, `cache`, `db` oraz `client`, po czym
sprawdza, że ścieżki dozwolone działają, a każda zabroniona jest blokowana
(zob. §5).

### Budowa obrazów maszyn

```sh
make images          # wszystkie obrazy do ./images/<host>.qcow2
make image-www       # pojedyncza maszyna
# albo bezpośrednio:
nix build .#image-gateway .#image-www .#image-cache .#image-db
```

### Postawienie / usunięcie klastra na hoście libvirt

```sh
export IMG_DIR=/var/lib/wso/images
sudo -E make up           # utwórz sieci, potem maszyny
make status
make console www          # podłącz konsolę szeregową
sudo make down            # usuń wszystko
```

Podkomendy `vmctl`: `up`, `down`, `net-up`, `net-down`, `vm-up`, `vm-down`,
`status`, `console <host>`, `help`.

### Wdrożenie przez nixos-rebuild zamiast obrazów

```sh
make deploy HOST=www IP=10.10.0.10
# albo bezpośrednio:
nixos-rebuild switch --flake .#www --target-host root@10.10.0.10
```

### Budowa raportu PDF

```sh
make report          # tworzy report/raport.pdf
```

## 5. Plan testów (koncepcja §5)

`tests/integration.nix` koduje obie części planu i dokłada przypadki negatywne,
które nadają im sens:

* **Widoczność ICMP** — `www` pinguje `cache`, `cache` pinguje `db` (warstwy
  sąsiednie); `client` **nie** pinguje żadnego hosta wewnętrznego (ICMP nigdy
  nie jest przekazywany przez brzeg); `db` **nie** inicjuje ruchu (brak egress).
* **Skan `nmap`** — z Internetu widoczne są wyłącznie porty `80/443` na adresie
  publicznym bramy; porty `22`, `5432`, `6379` są niewidoczne.
* **Osiągalność** — serwis odpowiada przez adres publiczny (DNAT); dozwolone są
  `www→cache:6379` oraz `cache→db:5432`; zablokowane `www→db:5432`,
  `client→cache:6379`, `client→db:5432`.

## 6. Model bezpieczeństwa (skrót)

Pełne omówienie znajduje się w [`report/raport.tex`](report/raport.tex).
W skrócie:

* **Segmentacja + najmniejsze uprawnienia.** Jeden segment L2 na połączenie,
  polityka *default-deny*, usługi udostępniane wyłącznie temu sąsiadowi, który
  ich potrzebuje — z dopasowaniem po *adresie źródłowym*, nie tylko porcie.
* **Obrona w głąb.** Filtracja sieciowa *oraz* zabezpieczenia na poziomie usług
  (Redis powiązany z jednym interfejsem + hasło; PostgreSQL powiązany + `pg_hba`
  + scram).
* **Minimalny zasięg skutków.** Baza nie ma egress ani trasy domyślnej; brama
  wystawiona na Internet nie uruchamia żadnej usługi aplikacyjnej.
* **Reprodukowalność jako bezpieczeństwo.** Cała konfiguracja jest deklaratywna
  i wersjonowana, co eliminuje dryf konfiguracji i pozwala audytować dopuszczony
  ruch z jednego modelu.

**Niewłaściwe sposoby użycia, których należy unikać** (również w raporcie):
wystawianie Redis/PostgreSQL na adresie „wildcard”, traktowanie NAT jak zapory,
rozszerzanie zakresu źródeł SSH do `0.0.0.0/0`, umieszczanie w repozytorium
demonstracyjnego `requirePass`/poświadczeń, czy spłaszczanie segmentów do jednej
wspólnej sieci.

## 7. Uwagi i ograniczenia

* Demonstracyjny certyfikat TLS warstwy WWW jest samopodpisany i generowany przy
  budowaniu; w produkcji należy użyć ACME lub certyfikatu dostarczonego.
* `requirePass = "change-me-redis"` oraz rola PostgreSQL to zaślepki — prawdziwe
  sekrety należy dostarczyć poza repozytorium (np. `requirePassFile`,
  agenix/sops).
* Segment `wan` to sieć NAT libvirt na potrzeby laboratorium; aby udostępnić
  serwis na zewnątrz, należy zmostkować ją lub przekierować (DNAT) porty 80/443
  na hoście do adresu `192.0.2.1`.
* Zbudowane i przeznaczone dla architektury `x86_64-linux`.
