let nixpkgsSrc = import ./mach_nix/nix/nixpkgs-src.nix; in
{
  pkgs ? import nixpkgsSrc { config = {}; overlays = []; },
  ...
}:
with builtins;
let
  python = import ./mach_nix/nix/python.nix { inherit pkgs; };
  python_deps = (builtins.attrValues (import ./mach_nix/nix/python-deps.nix { inherit python; fetchurl = pkgs.fetchurl; }));
  mergeOverrides = with pkgs.lib; foldl composeExtensions (self: super: { });
  autoPatchelfHook = import ./mach_nix/nix/auto_patchelf_hook.nix {inherit (pkgs) fetchurl makeSetupHook writeText;};
  pypiFetcher = (import ./mach_nix/nix/deps-db-and-fetcher.nix { inherit pkgs; }).pypi_fetcher;
  withDot = mkPython: import ./mach_nix/nix/withDot.nix { inherit mkPython pypiFetcher; };

  concat_reqs = reqs_list:
    let
      concat = s1: s2: s1 + "\n" + s2;
    in
      builtins.foldl' concat "" reqs_list;

  extract = python: src: fail_msg:
    let
      file_path = "${(import ./lib/extractor).extract_from_src {
          py = python;
          src = src;
        }}/python.json";
    in
      if pathExists file_path then fromJSON (readFile file_path) else throw fail_msg;

  extract_requirements = python: src: name: extras:
     with pkgs.lib;
    let
      data = extract python src ''
        Automatic requirements extraction failed for ${name}.
        Please manually specify 'requirements' '';
      setup_requires = if hasAttr "setup_requires" data then data.setup_requires else [];
      install_requires = if hasAttr "install_requires" data then data.install_requires else [];
      extras_require =
        if hasAttr "extras_require" data then
          pkgs.lib.flatten (map (extra: data.extras_require."${extra}") extras)
        else [];
      all_reqs = concat_reqs (setup_requires ++ install_requires ++ extras_require);
      msg = "\n automatically detected requirements of ${name} ${version}:${all_reqs}\n\n";
    in
      trace msg all_reqs;

  extract_meta = python: src: attr: for_attr:
    with pkgs.lib;
    let
      error_msg = ''
        Automatic extraction of '${for_attr}' from python package source ${src} failed.
        Please manually specify '${for_attr}' '';
      data = extract python src error_msg;
      result = if hasAttr attr data then data."${attr}" else throw error_msg;
      msg = "\n automatically detected ${for_attr}: '${result}'";
    in
      trace msg result;

  is_src = input: ! input ? passthru;

  is_http_url = url:
    with builtins;
    if (substring 0 8 url) == "https://" || (substring 0 7 url) == "http://" then true else false;

  get_src = src:
    with builtins;
    if isString src && is_http_url src then (fetchTarball src) else src;

  get_py_ver = python: with pkgs.lib; {
    major = elemAt (splitString "." python.version) 0;
    minor = elemAt (splitString "." python.version) 1;
  };

  combine = pname: key: val1: val2:
    if isList val2 then val1 ++ val2
    else if isAttrs val2 then val1 // val2
    else if isString val2 then val1 + val2
    else throw "_.${pname}.${key}.add only accepts list or attrs or string.";

  meets_cond = oa: condition:
    let
      provider = if hasAttr "provider" oa.passthru then oa.passthru.provider else "nixpkgs";
    in
      condition { prov = provider; ver = oa.version; pyver = oa.pythonModule.version; };

  simple_overrides = args: with pkgs.lib;
    flatten ( mapAttrsToList (pkg: keys: pySelf: pySuper: {
      "${pkg}" = pySuper."${pkg}".overrideAttrs (oa:
        mapAttrs (key: val:
          if isAttrs val && hasAttr "add" val then
            combine pkg key oa."${key}" val.add
          else if isAttrs val && hasAttr "mod" val && isFunction val.mod then
            let result = val.mod oa."${key}"; in
              # if the mod function wants more argument, call with more arguments (alternative style)
              if ! isFunction result then
                result
              else
                val.mod pySelf oa oa."${key}"
          else
            val
        ) keys
      );
    }) args);

  fixes_to_overrides = fixes: with pkgs.lib;
    flatten (flatten (
      mapAttrsToList (pkg: p_fixes:
        mapAttrsToList (fix: keys: pySelf: pySuper:
          let cond = if hasAttr "_cond" keys then keys._cond else ({prov, ver, pyver}: true); in
          if ! hasAttr "${pkg}" pySuper then {} else
          {
            "${pkg}" = pySuper."${pkg}".overrideAttrs (oa:
              mapAttrs (key: val:
                trace "\napplying fix '${fix}' (${key}) for ${pkg}:${oa.version}\n" (
                  if isAttrs val && hasAttr "add" val then
                    combine pkg key oa."${key}" val.add
                  else if isAttrs val && hasAttr "mod" val && isFunction val.mod then
                    let result = val.mod oa."${key}"; in
                      # if the mod function wants more argument, call with more arguments (alternative style)
                      if ! isFunction result then
                        result
                      else
                          val.mod pySelf oa oa."${key}"
                  else
                    val
                )
              ) (filterAttrs (k: v: k != "_cond" && meets_cond oa cond) keys)
            );
          }
        ) p_fixes
      ) fixes
    ));

  # call this to generate a nix expression which contains the mach-nix overrides
  compileExpression = args: import ./mach_nix/nix/mach.nix args;

  # Returns `overrides` and `select_pkgs` which satisfy your requirements
  compileOverrides = args:
    let
      result = import "${compileExpression args}/share/mach_nix_file.nix" { pkgs = args.pkgs; };
      manylinux =
        if args.pkgs.stdenv.hostPlatform.system == "x86_64-darwin" then
          []
        else
          args.pkgs.pythonManylinuxPackages.manylinux1;
    in {
      overrides = result.overrides manylinux autoPatchelfHook;
      select_pkgs = result.select_pkgs;
    };

  __buildPython = with builtins; func: args:
    if args ? pkgs then
      throw "${func} does not accept 'pkgs' anymore. 'pkgs' need to be specified when importing mach-nix"
    else if args ? extra_pkgs then
      throw "'extra_pkgs' cannot be passed to ${func}. Please pass it to a mkPython call."
    else if isString args || isPath args || pkgs.lib.isDerivation args then
      _buildPython func { src = args; }
    else
      _buildPython func args;

  _buildPython = func: args@{
      add_requirements ? "",  # add additional requirements to the packge
      requirements ? null,  # content from a requirements.txt file
      disable_checks ? true,  # Disable tests wherever possible to decrease build time.
      extras ? [],
      doCheck ? ! disable_checks,
      overrides_pre ? [],  # list of pythonOverrides to apply before the machnix overrides
      overrides_post ? [],  # list of pythonOverrides to apply after the machnix overrides
      passthru ? {},
      providers ? {},  # define provider preferences
      pypi_deps_db_commit ? builtins.readFile ./mach_nix/nix/PYPI_DEPS_DB_COMMIT,  # python dependency DB version
      pypi_deps_db_sha256 ? builtins.readFile ./mach_nix/nix/PYPI_DEPS_DB_SHA256,
      python ? "python3",  # select custom python to base overrides onto. Should be from nixpkgs >= 20.03
      _provider_defaults ? with builtins; fromTOML (readFile ./mach_nix/provider_defaults.toml),
      _ ? {},  # simplified overrides
      _fixes ? import ./mach_nix/fixes.nix {pkgs = pkgs;},
      ...
    }:
    with builtins;
    let
      python_arg = if isString python then python else throw '''python' must be a string. Example: "python38"'';
    in
    let
      python_pkg = pkgs."${python_arg}";
      src = get_src pass_args.src;
      # Extract dependencies automatically if 'requirements' is unset
      pname =
        if hasAttr "pname" args then args.pname
        else extract_meta python_pkg src "name" "pname";
      version =
        if hasAttr "version" args then args.version
        else extract_meta python_pkg src "version" "version";
      meta_reqs = extract_requirements python_pkg src "${pname}:${version}" extras;
      reqs =
        (if requirements == null then
          if builtins.hasAttr "format" args && args.format != "setuptools" then
            throw "Automatic dependency extraction is only available for 'setuptools' format."
                  " Please specify 'requirements' if setuptools is not used."
          else
            meta_reqs
        else
          requirements)
        + "\n" + add_requirements;
      py = python_pkg.override { packageOverrides = mergeOverrides overrides_pre; };
      result = compileOverrides {
        inherit disable_checks pkgs providers pypi_deps_db_commit pypi_deps_db_sha256 _provider_defaults;
        overrides = overrides_pre;
        python = py;
        requirements = reqs;
      };
      py_final = python_pkg.override { packageOverrides = mergeOverrides (
        overrides_pre ++ [ result.overrides ] ++ (fixes_to_overrides _fixes) ++ overrides_post ++ (simple_overrides _)
      );};
      pass_args = removeAttrs args (builtins.attrNames ({
        inherit add_requirements disable_checks overrides_pre overrides_post pkgs providers
                requirements pypi_deps_db_commit pypi_deps_db_sha256 python _provider_defaults _ ;
      }));
    in
    py_final.pkgs."${func}" ( pass_args // {
      propagatedBuildInputs =
        (result.select_pkgs py_final.pkgs)
        ++ (if hasAttr "propagatedBuildInputs" args then args.propagatedBuildInputs else []);
      src = src;
      inherit doCheck pname version;
      passthru = passthru // {
        requirements = reqs;
        inherit overrides_pre overrides_post _;
      };
    });


  # (High level API) generates a python environment with minimal user effort
  mkPythonBase = caller: args:
    if args ? pkgs then
      throw "${caller} does not accept 'pkgs' anymore. 'pkgs' need to be specified when importing mach-nix"
    else if builtins.isList args then
      _mkPythonBase { extra_pkgs = args; }
    else
      _mkPythonBase args;

  _mkPythonBase =
    {
      requirements ? "",  # content from a requirements.txt file
      disable_checks ? true,  # Disable tests wherever possible to decrease build time.
      extra_pkgs ? [],
      overrides_pre ? [],  # list of pythonOverrides to apply before the machnix overrides
      overrides_post ? [],  # list of pythonOverrides to apply after the machnix overrides
      providers ? {},  # define provider preferences
      pypi_deps_db_commit ? builtins.readFile ./mach_nix/nix/PYPI_DEPS_DB_COMMIT,  # python dependency DB version
      pypi_deps_db_sha256 ? builtins.readFile ./mach_nix/nix/PYPI_DEPS_DB_SHA256,
      python ? "python3",  # select custom python to base overrides onto. Should be from nixpkgs >= 20.03
      _ ? {},  # simplified overrides
      _provider_defaults ? with builtins; fromTOML (readFile ./mach_nix/provider_defaults.toml),
      _fixes ? import ./mach_nix/fixes.nix {pkgs = pkgs;}
    }:
    with builtins;
    with pkgs.lib;
    let
      python_arg = if isString python then python else throw '''python' must be a string. Example: "python38"'';
    in
    let
      python_pkg = pkgs."${python_arg}";
      pyver = get_py_ver python_pkg;
      # and separate pkgs into groups
      extra_pkgs_python = map (p:
        # check if element is a package built via mach-nix
        if p ? pythomModule && ! p ? passthru._ then
          throw ''
            python packages from nixpkgs cannot be passed via `extra_pkgs`.
            Instead, add the package's name to your `requirements` and set `providers.{package} = "nixpkgs"`
          ''
        else if p ? passthru._ then
          let
            pkg_pyver = get_py_ver p.pythonModule;
          in
            if pkg_pyver != pyver then
              throw ''
                ${p.pname} from 'extra_pkgs' is built with python ${p.pythonModule.version},
                but the environment is based on python ${pyver.major}.${pyver.minor}.
                Please build ${p.pname} with 'python = "python${pyver.major}${pyver.minor}"'.
              ''
            else
              p
        # translate sources to python packages
        else
          _buildPython "buildPythonPackage" {
            src = p;
            inherit disable_checks pkgs providers pypi_deps_db_commit pypi_deps_db_sha256 python _provider_defaults;
          }
      ) (filter (p: is_src p || p ? pythonModule) extra_pkgs);
      extra_pkgs_r = filter (p: p ? rCommand) extra_pkgs;
      extra_pkgs_other = filter (p: ! (p ? rCommand || p ? pythonModule || is_src p)) extra_pkgs;

      # gather requirements of exra pkgs
      extra_pkgs_py_reqs =
        map (p:
          if hasAttr "requirements" p then p.requirements
          else throw "Packages passed via 'extra_pkgs' must be built via mach-nix.buildPythonPackage"
        ) extra_pkgs_python;
      extra_pkgs_r_reqs = if extra_pkgs_r == [] then "" else ''
        rpy2
        ipython
        jinja2
        pytz
        pandas
        numpy
        cffi
        tzlocal
        simplegeneric
      '';

      # gather overrides necessary by extra_pkgs
      extra_pkgs_python_attrs = foldl' (a: b: a // b) {} (map (p: { "${p.pname}" = p; }) extra_pkgs_python);
      extra_pkgs_py_overrides = [ (pySelf: pySuper: extra_pkgs_python_attrs) ];
      extra_pkgs_r_overrides = simple_overrides {
        rpy2.buildInputs.add = extra_pkgs_r;
      };
      overrides_simple_extra = flatten (
        (map simple_overrides (
          map (p: if hasAttr "_" p then p._ else {}) extra_pkgs_python
        ))
      );
      overrides_pre_extra = flatten (map (p: p.passthru.overrides_pre) extra_pkgs_python);
      overrides_post_extra = flatten (map (p: p.passthru.overrides_post) extra_pkgs_python);

      py = python_pkg.override { packageOverrides = mergeOverrides overrides_pre; };
      result = compileOverrides {
        inherit disable_checks pkgs providers pypi_deps_db_commit pypi_deps_db_sha256 _provider_defaults;
        overrides = overrides_pre ++ overrides_pre_extra ++ extra_pkgs_py_overrides;
        python = py;
        requirements = concat_reqs ([requirements] ++ extra_pkgs_py_reqs ++ [extra_pkgs_r_reqs]);
      };
      all_overrides = mergeOverrides (
        overrides_pre ++ overrides_pre_extra
        ++ extra_pkgs_py_overrides
        ++ [ result.overrides ]
        ++ (fixes_to_overrides _fixes)
        ++ overrides_post_extra ++ overrides_post
        ++ extra_pkgs_r_overrides
        ++ overrides_simple_extra ++ (simple_overrides _)
      );
      py_final = python_pkg.override { packageOverrides = all_overrides;};
      select_pkgs = ps:
        (result.select_pkgs ps)
        ++ (map (name: ps."${name}") (attrNames extra_pkgs_python_attrs));
      py_final_with_pkgs = py_final.withPackages (ps: select_pkgs ps);
      final_env = pkgs.buildEnv {
        name = "mach-nix-python-env";
        paths = [
          py_final_with_pkgs
          extra_pkgs_other
        ];
      };
    in let
      self = final_env.overrideAttrs (oa: {
        passthru = oa.passthru // rec {
          selectPkgs = select_pkgs;
          pythonOverrides = all_overrides;
          python = py_final;
          env = pkgs.mkShell {
            name = "mach-nix-python-shell";
            buildInputs = [ final_env ];
          };
          overlay = self: super:
            let
              py_attr_name = "python${pyver.major}${pyver.minor}";
            in
              {
                "${py_attr_name}" = super."${py_attr_name}".override {
                  packageOverrides = pythonOverrides;
                };
              };
          nixpkgs = import pkgs.path { config = pkgs.config; overlays = pkgs.overlays ++ [ overlay ]; };
          dockerImage = makeOverridable
            (args: pkgs.dockerTools.buildLayeredImage args)
            {
              name = "mach-nix-python";
              tag = "latest";
              contents = [
                pkgs.busybox
                self
              ];
              config = {
                Cmd = [ "${self}/bin/python" ];
                Env = {
                  python = "${self}";
                };
              };
            };
        };
      });
    in self;
in
rec {
  # the mach-nix cmdline tool derivation
  mach-nix = python.pkgs.buildPythonPackage rec {
    pname = "mach-nix";
    version = builtins.readFile ./mach_nix/VERSION;
    name = "${pname}-${version}";
    src = ./.;
    propagatedBuildInputs = python_deps;
    doCheck = false;
  };

  # the main functions
  mkPython = args: mkPythonBase "mkPython" args;
  mkPythonShell = args: (mkPythonBase "mkPythonShell" args).env;
  mkDockerImage = args: (mkPythonBase "mkDockerImage" args).dockerImage;
  mkOverlay = args: (mkPythonBase "mkOverlay" args).overlay;
  mkNixpkgs = args: (mkPythonBase "mkNixpkgs" args).nixpkgs;
  mkPythonOverrides = args: (mkPythonBase "mkPythonOverrides" args).pythonOverrides;

  # equivalent to buildPythonPackage of nixpkgs
  buildPythonPackage = __buildPython "buildPythonPackage";

  # equivalent to buildPythonApplication of nixpkgs
  buildPythonApplication = __buildPython "buildPythonApplication";

  # provide pypi fetcher to user
  fetchPypiSdist = pypiFetcher.fetchPypiSdist;
  fetchPypiWheel = pypiFetcher.fetchPypiWheel;

  # expose dot interface for flakes cmdline
  "with" = (withDot (mkPythonBase "'.with'"))."with";
  pythonWith = (withDot (mkPythonBase "'.pythonWith'")).pythonWith;
  shellWith = (withDot (mkPythonBase "'.shellWith'")).shellWith;
  dockerImageWith = (withDot (mkPythonBase "'.dockerImageWith'")).dockerImageWith;

  # expose mach-nix' nixpkgs
  # those are equivalent to the pkgs passed by the user
  nixpkgs = pkgs;

  # expose R packages
  rPackages = pkgs.rPackages;

  # this might beuseful for someone
  inherit mergeOverrides;
}
