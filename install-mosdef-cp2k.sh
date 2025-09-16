#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config (tweak if desired)
# =========================
ENV_NAME="${ENV_NAME:-mosdef-env}"
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"

# Always prefer user-local Miniforge over any system/root conda
PREFER_CONDA_HOME="${PREFER_CONDA_HOME:-true}"

# Where to install Miniforge if conda isn't found:
CONDA_HOME="${CONDA_HOME:-$HOME/miniforge3}"
CONDA_BIN="${CONDA_HOME}/bin/conda"
MAMBA_BIN="${CONDA_HOME}/bin/mamba"
CHANNELS="-c conda-forge"

# Make conda available in NEW shells? (runs `conda init`)
INIT_SHELL="${INIT_SHELL:-true}"   # true|false

# Optional toggles
INSTALL_ENGINES="${INSTALL_ENGINES:-true}"
ENABLE_CUDA="${ENABLE_CUDA:-false}"          # true|false
CUDA_VERSION="${CUDA_VERSION:-12.4}"         # 12.4 / 12.2 / 11.8, etc.

# Core MoSDeF + ecosystem packages (NumPy/ParmEd pinned for compatibility)
MOSDEF_PKGS=(
  python=${PYTHON_VERSION}
  pip
  # MoSDeF core
  foyer mbuild gmso unyt
  # Workflow helpers
  signac signac-flow signac-dashboard
  # Utilities (pin for ParmEd compatibility)
  "numpy<2" scipy pandas mdtraj "parmed<4" openmm
  # I/O & viz
  jupyterlab nglview matplotlib
  # Packing & builders
  packmol mosdef_cassandra netcdf4
)

ENGINE_PKGS=( lammps hoomd gromacs )  # CLI: lmp, gmx; hoomd is a Python module
CP2K_PKG=( cp2k )                     # CPU build

# =========================
# Helpers
# =========================
msg()  { echo -e "\n\033[1;32m==> $*\033[0m"; }
warn() { echo -e "\n\033[1;33m[!] $*\033[0m"; }
die()  { echo -e "\n\033[1;31m[ERROR] $*\033[0m"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# Refuse to proceed if a non-root user would install to /root
if [ "$(id -u)" -ne 0 ] && [[ "$CONDA_HOME" == /root/* ]]; then
  die "CONDA_HOME points to /root but you are not root. Set CONDA_HOME to \$HOME/miniforge3."
fi

# Refuse to use a prefix we cannot write
if [ -e "$CONDA_HOME" ] && [ ! -w "$CONDA_HOME" ]; then
  die "CONDA_HOME ($CONDA_HOME) exists but is not writable by $(whoami). Choose a different CONDA_HOME."
fi

# Portable activator that works even if conda isn't init'd in your shell.
conda_eval_hook() {
  if [ "${PREFER_CONDA_HOME}" = "true" ] && [ -x "$CONDA_BIN" ]; then
    eval "$("$CONDA_BIN" shell.bash hook)"
    return 0
  fi
  if command -v conda >/dev/null 2>&1; then
    eval "$(conda shell.bash hook)"
    return 0
  fi
  if [ -x "$CONDA_BIN" ]; then
    eval "$("$CONDA_BIN" shell.bash hook)"
    return 0
  fi
  return 1
}

install_miniforge() {
  msg "Installing Miniforge (conda-forge) into: $CONDA_HOME"
  need_cmd curl
  local os arch installer
  os="$(uname -s)"; arch="$(uname -m)"
  case "${os}-${arch}" in
    Linux-x86_64)  installer="Miniforge3-Linux-x86_64.sh" ;;
    Linux-aarch64) installer="Miniforge3-Linux-aarch64.sh" ;;
    Darwin-arm64)  installer="Miniforge3-MacOSX-arm64.sh" ;;
    Darwin-x86_64) installer="Miniforge3-MacOSX-x86_64.sh" ;;
    *) die "Unsupported platform: ${os}-${arch}" ;;
  esac

  mkdir -p "$CONDA_HOME"
  curl -fsSL -o "/tmp/${installer}" "https://github.com/conda-forge/miniforge/releases/latest/download/${installer}"
  # If dir exists, update in-place; else fresh install
  local flags="-b -p"; [ -d "$CONDA_HOME" ] && flags="-b -u -p"
  bash "/tmp/${installer}" $flags "$CONDA_HOME"
  rm -f "/tmp/${installer}"

  # Sanity
  [ -x "$CONDA_BIN" ] || die "Miniforge install failed at $CONDA_HOME (conda missing)."
}

ensure_conda_ready() {
  # Always use our explicit CONDA_HOME
  if [ ! -x "$CONDA_BIN" ]; then
    msg "Conda not found at $CONDA_BIN \u2014 installing Miniforge to $CONDA_HOME"
    install_miniforge
  fi
  # Load conda into THIS process
  eval "$("$CONDA_BIN" shell.bash hook)" || die "Failed to initialize conda shell hook"
  msg "Conda base: $(conda info --base)"
  # Ensure mamba exists in base (idempotent)
  "$CONDA_BIN" install -y ${CHANNELS} mamba || true
}

set_conda_cfg() {
  # Back-compat helper for the pip interop key rename
  local scope="--env"
  local key="$1"
  local val="$2"
  if ! conda config $scope --set "$key" "$val" >/dev/null 2>&1; then
    if [ "$key" = "prefix_data_interoperability" ]; then
      conda config $scope --set pip_interop_enabled "$val" >/dev/null 2>&1 || true
    fi
  fi
}

create_env() {
  msg "Creating environment: $ENV_NAME (Python $PYTHON_VERSION)"
  conda deactivate >/dev/null 2>&1 || true
  conda env remove -y -n "$ENV_NAME" >/dev/null 2>&1 || true

  set_conda_cfg channel_priority strict
  set_conda_cfg prefix_data_interoperability False

  "$MAMBA_BIN" create -y -n "$ENV_NAME" ${CHANNELS} "python=${PYTHON_VERSION}"
  conda activate "$ENV_NAME"

  # Hard pins to avoid NumPy 2 / ParmEd breakage & pkg_resources deprecation
  mkdir -p "$CONDA_PREFIX/conda-meta"
  cat > "$CONDA_PREFIX/conda-meta/pinned" <<'PIN'
numpy <2
parmed <4
setuptools <81
PIN
}

install_mosdef_stack() {
  msg "Installing MoSDeF core + helpers"
  "$MAMBA_BIN" install -y ${CHANNELS} "setuptools<81" "numpy=1.26.*" "parmed<4"
  "$MAMBA_BIN" install -y ${CHANNELS} "${MOSDEF_PKGS[@]}"

  if [ "${ENABLE_CUDA}" = "true" ]; then
    msg "CUDA enabled: installing cudatoolkit=${CUDA_VERSION}"
    "$MAMBA_BIN" install -y ${CHANNELS} "cudatoolkit=${CUDA_VERSION}" --freeze-installed
  fi
}

install_engines() {
  [ "${INSTALL_ENGINES}" = "true" ] || { msg "Skipping engine installs"; return; }

  msg "Installing simulation engines"
  # Fast path
  set +e
  "$MAMBA_BIN" install -y ${CHANNELS} "${ENGINE_PKGS[@]}"
  rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    return 0
  fi

  warn "Bulk engine install failed (rc=$rc). Retrying sequentially with pins & low-memory settings..."
  export MAMBA_NUM_THREADS=1
  mamba clean -y --index-cache --tarballs || true

  # If CUDA is enabled, pin cudatoolkit first to constrain the solve
  if [ "${ENABLE_CUDA}" = "true" ]; then
    "$MAMBA_BIN" install -y ${CHANNELS} "cudatoolkit=${CUDA_VERSION}" --freeze-installed || \
      die "Failed to install cudatoolkit=${CUDA_VERSION}"
  fi

  local PINS=(
    "lammps=2024.06.27"
    "hoomd=4.6.*"
    "gromacs=2024.2"
  )
  for spec in "${PINS[@]}"; do
    msg "Installing ${spec}..."
    "$MAMBA_BIN" install -y ${CHANNELS} "${spec}" --freeze-installed || die "Failed to install ${spec}"
  done
}

install_cp2k() {
  msg "Installing CP2K (CPU)"
  "$MAMBA_BIN" install -y ${CHANNELS} "${CP2K_PKG[@]}"
}

# --- NEW: Ensure CP2K data present and exported ---
ensure_cp2k_data() {
  local d1="$CONDA_PREFIX/share/cp2k/data"
  local d2="$CONDA_PREFIX/share/cp2k"

  if [ -f "$d1/BASIS_MOLOPT" ] && [ -f "$d1/POTENTIAL" ]; then
    export CP2K_DATA_DIR="$d1"
  elif [ -f "$d2/BASIS_MOLOPT" ] && [ -f "$d2/POTENTIAL" ]; then
    export CP2K_DATA_DIR="$d2"
  else
    msg "CP2K data files not found in env; fetching from upstream (v2024.2)..."
    mkdir -p "$d2"
    curl -fsSL -o "$d2/BASIS_MOLOPT" https://raw.githubusercontent.com/cp2k/cp2k/v2024.2/data/BASIS_MOLOPT
    curl -fsSL -o "$d2/POTENTIAL"    https://raw.githubusercontent.com/cp2k/cp2k/v2024.2/data/POTENTIAL
    export CP2K_DATA_DIR="$d2"
  fi

  # Validate again (fail-fast)
  [ -f "$CP2K_DATA_DIR/BASIS_MOLOPT" ] && [ -f "$CP2K_DATA_DIR/POTENTIAL" ] \
    || die "CP2K data missing after setup (looked in $d1 and $d2)."
  msg "CP2K_DATA_DIR set to: $CP2K_DATA_DIR"
}

make_activation_shims() {
  # One-shot activation shim (works in any shell without conda init)
  local shim="$CONDA_HOME/envs/${ENV_NAME}/activate.sh"
  msg "Creating activation shim: $shim"
  mkdir -p "$(dirname "$shim")"
  cat > "$shim" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# This script assumes it lives inside the same conda prefix as the env.
# Resolve CONDA_HOME from this file path:
SELF="$(readlink -f "$0")"
ENV_DIR="$(dirname "$SELF")"
CONDA_HOME="$(dirname "$(dirname "$ENV_DIR")")"
CONDA_BIN="$CONDA_HOME/bin/conda"
eval "$("$CONDA_BIN" shell.bash hook)"
conda activate "$(basename "$ENV_DIR")"
# Teach CP2K where its data lives
if [ -d "$CONDA_PREFIX/share/cp2k/data" ]; then
  export CP2K_DATA_DIR="$CONDA_PREFIX/share/cp2k/data"
else
  export CP2K_DATA_DIR="$CONDA_PREFIX/share/cp2k"
fi
EOF
  chmod +x "$shim"

  # Convenience launcher in ~/.local/bin if available
  if [ -d "$HOME/.local/bin" ] && [ -w "$HOME/.local/bin" ]; then
    local link="$HOME/.local/bin/activate-${ENV_NAME}"
    ln -sf "$shim" "$link"
    msg "Created convenience launcher: $link"
  fi

  # Optionally make conda available in NEW shells
  if [ "${INIT_SHELL}" = "true" ]; then
    msg "Initializing conda for new shells (bash/zsh)..."
    "$CONDA_BIN" init bash || true
    "$CONDA_BIN" init zsh  || true
    echo -e "\n[Info] Open a NEW terminal, or run:\n  eval \"\$($CONDA_BIN shell.bash hook)\"\nthen:\n  conda activate ${ENV_NAME}"
  else
    msg "Skipping 'conda init' (INIT_SHELL=false). Use the shim:\n  $shim"
  fi
}

post_setup() {
  msg "Post-setup checks & Jupyter/NGView wiring"
  if command -v jupyter >/dev/null 2>&1; then
    jupyter nbextension enable --py nglview --sys-prefix >/dev/null 2>&1 || true
  fi

  # Import smoke test (reports exact failures)
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
print("\u2713 MoSDeF imports OK | NumPy", numpy.__version__, "| ParmEd", parmed.__version__)
PY

  # GPU sanity if requested
  if [ "${ENABLE_CUDA}" = "true" ]; then
    python - <<'PY' || true
try:
    from openmm import Platform
    plats=[Platform.getPlatform(i).getName() for i in range(Platform.getNumPlatforms())]
    print("OpenMM platforms:", plats)
except Exception as e:
    print("[!] OpenMM GPU check failed:", e)
PY
  fi

  # Version checks (handle HOOMD as Python module; CP2K variants)
  python - <<'PY'
import platform, subprocess, shutil, os, textwrap
def ver(cmd):
    if shutil.which(cmd[0]) is None:
        print("$", " ".join(cmd), "\n  (not found on PATH)")
        return False
    try:
        out = subprocess.check_output(cmd, text=True).strip().splitlines()[0]
        print("$", " ".join(cmd), "\n ", out)
        return True
    except Exception as e:
        print("$", " ".join(cmd), "\n  (failed)", e)
        return False

print("=== Versions ===")
print("Python:", platform.python_version())
ver(["lmp","-h"])
ver(["gmx","--version"])
try:
    import hoomd, importlib.metadata as im
    hv = getattr(hoomd,"__version__", None) or im.version("hoomd")
    print("HOOMD (python):", hv)
except Exception as e:
    print("[!] HOOMD import failed:", e)

# CP2K checks
cp2k_bin = None
for b in ("cp2k.psmp","cp2k.popt","cp2k.ssmp","cp2k.sopt"):
    if shutil.which(b):
        cp2k_bin = b; break
if cp2k_bin:
    ver([cp2k_bin,"--version"])
    # Minimal ENERGY sanity run (in a temp dir)
    import tempfile, pathlib, subprocess
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="cp2k-smoke-"))
    inp = tmp/"h2o_energy.inp"
    data_dir = os.environ.get("CP2K_DATA_DIR", "")
    basis = "BASIS_MOLOPT"; pot = "POTENTIAL"
    if data_dir:
        basis = f"{data_dir}/BASIS_MOLOPT"
        pot   = f"{data_dir}/POTENTIAL"
    inp.write_text(textwrap.dedent(f"""
    &GLOBAL
      PROJECT H2O-test
      RUN_TYPE ENERGY
      PRINT_LEVEL LOW
    &END GLOBAL
    &FORCE_EVAL
      METHOD Quickstep
      &DFT
        BASIS_SET_FILE_NAME  {basis}
        POTENTIAL_FILE_NAME  {pot}
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
    """).strip()+"\n")
    try:
        subprocess.check_call([cp2k_bin, "-i", str(inp), "-o", str(tmp/"h2o_energy.out")])
        print("CP2K smoke test: SUCCESS")
    except Exception as e:
        print("[!] CP2K smoke test FAILED:", e)
else:
    print("[!] CP2K binary not found on PATH; expected one of psmp/popt/ssmp/sopt")
PY

  msg "Done. To use later:"
  echo "  $CONDA_HOME/envs/${ENV_NAME}/activate.sh"
}

# =========================
# Main
# =========================
main() {
  need_cmd curl
  ensure_conda_ready
  create_env
  install_mosdef_stack
  install_engines
  install_cp2k
  ensure_cp2k_data
  make_activation_shims
  post_setup

  cat <<NOTE

========================================================
MoSDeF + Engines + CP2K installed in conda env: ${ENV_NAME}

Conda base: $(conda info --base)
CUDA: ${ENABLE_CUDA}  (requested cudatoolkit: ${CUDA_VERSION})
Install engines: ${INSTALL_ENGINES}

Activate now (one-shot):
  ${CONDA_HOME}/envs/${ENV_NAME}/activate.sh

Or (if INIT_SHELL=true) open a NEW terminal, then:
  conda activate ${ENV_NAME}

Quick checks:
  lmp -h | head -n 1
  gmx --version | head -n 1
  python -c "import mbuild,foyer,gmso; print('MoSDeF ready')"
========================================================
NOTE
}

main "$@"