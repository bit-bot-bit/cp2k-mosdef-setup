# MoSDeF + Engines + CP2K Installer — README

This README explains how to **install**, **activate**, and **test** a full MoSDeF stack with optional engines (LAMMPS, HOOMD, GROMACS) and CP2K. It also includes validation commands and troubleshooting tips.

> **Do not run with `sudo`.** Install per-user into `~/miniforge3` by default.
> If you previously installed conda as root under `/root/miniforge3`, remove it or ignore it.

---

## 1) Prerequisites

* Linux or macOS shell with:
  * `bash`, `curl`
* No existing requirements for Python or CUDA (handled by conda/mamba).
* Sufficient disk space (\~10–20 GB depending on engines and caches).

---

## 2) Get the installer

Save your script as `mosdef.sh` and make it executable:

```bash
chmod +x mosdef.sh
```

Optionally choose a local conda prefix (default is `~/miniforge3`):

```bash
export CONDA_HOME="$HOME/miniforge3"
```

---

## 3) Quick install (CPU-only)

```bash
./mosdef.sh
```

What it does:

* Installs/updates **Miniforge** to `$CONDA_HOME`
* Ensures **mamba** in base
* Creates env **`mosdef-env`** (Python 3.11)
* Installs **MoSDeF** stack + **LAMMPS**, **HOOMD**, **GROMACS**, **CP2K**
* Ensures **CP2K data** and sets `CP2K_DATA_DIR`
* Creates one-shot activator: `~/miniforge3/envs/mosdef-env/activate.sh`
* Runs smoke checks and prints versions

---

## 4) Optional flags

Toggle via env vars **before** running `mosdef.sh`:

* **Engines**
  Skip LAMMPS/HOOMD/GROMACS:

  ```bash
  INSTALL_ENGINES=false ./mosdef.sh
  ```

* **CUDA** (toolkit only; engine GPU builds are not configured here)

  ```bash
  ENABLE_CUDA=true CUDA_VERSION=12.4 ./mosdef.sh
  ```

* **Conda prefix**

  ```bash
  CONDA_HOME="$HOME/miniforge3" ./mosdef.sh
  ```

* **Don’t modify your shell startup files**
  (skip `conda init`; use the activator script instead)

  ```bash
  INIT_SHELL=false ./mosdef.sh
  ```

---

## 5) Activate the environment

**One-shot activator (recommended):**

```bash
~/miniforge3/envs/mosdef-env/activate.sh
```

**Or, load conda in this shell and activate:**

```bash
eval "$($HOME/miniforge3/bin/conda shell.bash hook)"
conda activate mosdef-env
```

**Persistent (new terminals):**

```bash
$HOME/miniforge3/bin/conda init bash
# reopen terminal, then:
conda activate mosdef-env
```

---

## 6) Validate MoSDeF install

Imports (should print NumPy & ParmEd versions):

```bash
python - <<'PY'
mods = ["numpy","parmed","mbuild","foyer","gmso","unyt","signac","nglview","openmm"]
bad = []
for m in mods:
    try:
        __import__(m)
    except Exception as e:
        bad.append((m, repr(e)))
if bad:
    print("Import failures:")
    for m,e in bad: print(f" - {m}: {e}")
    raise SystemExit(1)
import numpy, parmed
print("✓ MoSDeF imports OK | NumPy", numpy.__version__, "| ParmEd", parmed.__version__)
PY
```

---

## 7) Validate engines

```bash
# LAMMPS
lmp -h | head -n 1

# GROMACS
gmx --version | head -n 1

# HOOMD (Python module)
python - <<'PY'
try:
    import hoomd, importlib.metadata as im
    print("HOOMD:", getattr(hoomd,"__version__", None) or im.version("hoomd"))
except Exception as e:
    print("[!] HOOMD import failed:", e)
PY
```

> Note: HOOMD may be CPU-only; GPU builds require a separate env.

---

## 8) Validate CP2K (binary + data + runs)

### 8.1 Ensure a binary is present

```bash
which cp2k.psmp || true
which cp2k.popt || true
which cp2k.ssmp || true   # conda-forge commonly ships this one
which cp2k.sopt || true

# Version
cp2k.ssmp --version
```

### 8.2 Ensure data directory

The installer sets `CP2K_DATA_DIR`. Verify:

```bash
# Prefer .../share/cp2k/data; else .../share/cp2k
if [ -d "$CONDA_PREFIX/share/cp2k/data" ]; then
  export CP2K_DATA_DIR="$CONDA_PREFIX/share/cp2k/data"
else
  export CP2K_DATA_DIR="$CONDA_PREFIX/share/cp2k"
fi

ls -l "$CP2K_DATA_DIR"/{BASIS_MOLOPT,POTENTIAL}
```

### 8.3 Minimal ENERGY test

```bash
cat > h2o_energy.inp <<'EOF'
&GLOBAL
  PROJECT H2O-test
  RUN_TYPE ENERGY
  PRINT_LEVEL LOW
&END GLOBAL
&FORCE_EVAL
  METHOD Quickstep
  &DFT
    BASIS_SET_FILE_NAME  BASIS_MOLOPT
    POTENTIAL_FILE_NAME  POTENTIAL
    &MGRID
      CUTOFF 100
    &END MGRID
    &XC
      &XC_FUNCTIONAL PBE
      &END XC_FUNCTIONAL
    &END XC
  &END DFT
  &SUBSYS
    &CELL
      ABC 10.0 10.0 10.0
    &END CELL
    &COORD
      O 0.000 0.000 0.000
      H 0.757 0.586 0.000
      H -0.757 0.586 0.000
    &END COORD
    &KIND H
      BASIS_SET DZVP-MOLOPT-GTH
      POTENTIAL GTH-PBE-q1
    &END KIND
    &KIND O
      BASIS_SET DZVP-MOLOPT-GTH
      POTENTIAL GTH-PBE-q6
    &END KIND
  &END SUBSYS
&END FORCE_EVAL
EOF

cp2k.ssmp -i h2o_energy.inp -o h2o_energy.out
grep -n "ENERGY|" h2o_energy.out | head
```

### 8.4 Forces test (optional)

```bash
cat > h2o_force.inp <<'EOF'
&GLOBAL
  PROJECT H2O-test
  RUN_TYPE ENERGY_FORCE
  PRINT_LEVEL LOW
&END GLOBAL
&FORCE_EVAL
  METHOD Quickstep
  &DFT
    BASIS_SET_FILE_NAME  BASIS_MOLOPT
    POTENTIAL_FILE_NAME  POTENTIAL
    &MGRID
      CUTOFF 100
    &END MGRID
    &SCF
      MAX_SCF 50
      &OT
        PRECONDITIONER FULL_SINGLE_INVERSE
        MINIMIZER DIIS
      &END OT
    &END SCF
    &XC
      &XC_FUNCTIONAL PBE
      &END XC_FUNCTIONAL
    &END XC
  &END DFT
  &SUBSYS
    &CELL
      ABC 10.0 10.0 10.0
    &END CELL
    &COORD
      O 0.000 0.000 0.000
      H 0.757 0.586 0.000
      H -0.757 0.586 0.000
    &END COORD
    &KIND H
      BASIS_SET DZVP-MOLOPT-GTH
      POTENTIAL GTH-PBE-q1
    &END KIND
    &KIND O
      BASIS_SET DZVP-MOLOPT-GTH
      POTENTIAL GTH-PBE-q6
    &END KIND
  &END SUBSYS
  &PRINT
    &FORCES ON
    &END FORCES
  &END PRINT
&END FORCE_EVAL
EOF

cp2k.ssmp -i h2o_force.inp -o h2o_force.out
grep -n "ATOMIC FORCES" h2o_force.out
```

> If something is odd, try `export OMP_NUM_THREADS=1` first.

---

## 9) CUDA sanity (optional)

If you installed the CUDA toolkit (`ENABLE_CUDA=true`):

```bash
python - <<'PY'
try:
    from openmm import Platform
    print([Platform.getPlatform(i).getName() for i in range(Platform.getNumPlatforms())])
except Exception as e:
    print("[!] OpenMM GPU check failed:", e)
PY
```

> Seeing “CUDA” in the platforms requires compatible drivers + GPU.
> Engines (HOOMD/GROMACS/LAMMPS) GPU builds are **not** installed by this script.

---

## 10) Troubleshooting

* **“conda: command not found”** (in a new shell)
  Either use the one-shot activator:

  ```bash
  ~/miniforge3/envs/mosdef-env/activate.sh
  ```

  or initialize conda for future shells:

  ```bash
  $HOME/miniforge3/bin/conda init bash
  exec bash
  ```

* **Permission denied** using `/root/miniforge3/...`
  You ran as root previously. Reinstall to your home:

  ```bash
  sudo rm -rf /root/miniforge3   # optional cleanup
  CONDA_HOME="$HOME/miniforge3" ./mosdef.sh
  ```

* **CP2K aborts reading `BASIS_MOLOPT`/`POTENTIAL`**
  Ensure data exists and `CP2K_DATA_DIR` is set (installer handles this; validate with):

  ```bash
  echo "$CP2K_DATA_DIR"
  ls -l "$CP2K_DATA_DIR"/{BASIS_MOLOPT,POTENTIAL}
  ```

* **Solver memory issues during engine installs**
  The script retries sequentially with pins and `MAMBA_NUM_THREADS=1`. If it still fails, re-run with:

  ```bash
  INSTALL_ENGINES=false ./mosdef.sh
  # later: conda activate mosdef-env && mamba install -c conda-forge lammps hoomd gromacs
  ```

---

## 11) Uninstall / Cleanup

```bash
# Remove the environment
eval "$($HOME/miniforge3/bin/conda shell.bash hook)"
conda env remove -n mosdef-env

# Remove Miniforge (only if you don’t need it)
rm -rf "$HOME/miniforge3"
```

---

## 12) Quick reference

```bash
# Install
./mosdef.sh

# Activate now
~/miniforge3/envs/mosdef-env/activate.sh

# Test MoSDeF
python -c "import mbuild,foyer,gmso; print('MoSDeF ready')"

# Test engines
lmp -h | head -n 1
gmx --version | head -n 1
python -c "import hoomd, importlib.metadata as im; print('HOOMD', getattr(hoomd,'__version__',None) or im.version('hoomd'))"

# Test CP2K
cp2k.ssmp --version
echo "$CP2K_DATA_DIR"
ls -l "$CP2K_DATA_DIR"/{BASIS_MOLOPT,POTENTIAL}
```
