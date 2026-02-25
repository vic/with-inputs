# Flake-inputs adapter.
#
# Mirrors flake inputs resolution without fetching or locking.
# Expects pre-fetched sources (npins, unflake, local paths, anything with .outPath).
#
# sources:  attrset of name -> sourceInfo (e.g. from npins)
# inputs:   attrset mirroring the `inputs` block of a flake.nix:
#   someLib.outPath = ./someLib;              local checkout (loaded as flake if possible)
#   b.follows = "a";                          alias to allInputs.a
#   b.follows = "a/x/y";                      nested follows
#   b.follows = "";                           intentionally empty
#   a.inputs.b.follows = "nixpkgs";           per-sub-input follows override
#   a = { outPath = ./a; inputs.b.follows = "x"; };  outPath + sub-input overrides
#   a = anyValue;                             direct value (function, attrset, …)
sources: inputs:
let
  splitPath = s: builtins.filter builtins.isString (builtins.split "/" s);

  isFollows = v: builtins.isAttrs v && v ? follows;

  # A spec is an attrset whose only keys are "follows" and/or "inputs",
  # where every inputs.* value is itself a follows spec.
  # Anything with outPath, lib, packages, … is a direct value, not a spec.
  isSpec =
    v:
    builtins.isAttrs v
    && (v ? follows || v ? inputs)
    && builtins.all (k: k == "follows" || k == "inputs") (builtins.attrNames v)
    && (!(v ? inputs) || builtins.all (k: isFollows v.inputs.${k}) (builtins.attrNames v.inputs));

  # Returns the resolved input, or null if any segment in the path is missing.
  walkPath =
    path:
    let
      segs = splitPath path;
      root = allInputs.${builtins.head segs} or null;
    in
    builtins.foldl' (node: seg: if node == null then null else node.inputs.${seg} or null) root (
      builtins.tail segs
    );

  # Per-sub-input override spec from inputs.${hostName}.inputs.${subName}.
  # Works regardless of whether the decl entry also has outPath or other fields.
  overrideSubSpec =
    hostName: subName:
    let
      entry = inputs.${hostName} or null;
    in
    if entry != null && builtins.isAttrs entry && entry ? inputs then
      entry.inputs.${subName} or null
    else
      null;

  # Resolve an inputs entry to an actual input value, or null if unresolvable.
  # Values with outPath but no _type go through mkInput so their flake.nix is loaded.
  resolveInput =
    name: v:
    if isFollows v then
      if v.follows == "" then { } else walkPath v.follows
    else if isSpec v then
      resolvedSources.${name} or { }
    else if v ? outPath && !(v ? _type) then
      mkInput name v
    else
      v;

  resolveSubInput =
    hostName: subName: declaredSpec:
    let
      ov = overrideSubSpec hostName subName;
      spec = if ov != null then ov else declaredSpec;
      walked = if isFollows spec then walkPath spec.follows else null;
      fromAll = allInputs.${subName} or null;
    in
    if isFollows spec then
      if spec.follows == "" then
        { }
      else if walked == null then
        { }
      else
        walked
    else if fromAll == null then
      { }
    else
      fromAll;

  canResolveSubInput =
    hostName: subName: declaredSpec:
    let
      ov = overrideSubSpec hostName subName;
      spec = if ov != null then ov else declaredSpec;
    in
    if isFollows spec then
      spec.follows == "" || walkPath spec.follows != null
    else
      allInputs ? ${subName} && allInputs.${subName} != null;

  mkInput =
    name: sourceInfo:
    let
      flakePath = sourceInfo.outPath + "/flake.nix";
    in
    if sourceInfo ? outPath && builtins.pathExists flakePath then
      mkFlakeInput name sourceInfo (import flakePath)
    else
      sourceInfo;

  mkFlakeInput =
    name: sourceInfo: flake:
    let
      specs = flake.inputs or { };
      names = builtins.attrNames specs;
      inputsOk = builtins.all (n: canResolveSubInput name n specs.${n}) names;
      inputs = builtins.mapAttrs (sub: spec: resolveSubInput name sub spec) specs;
      outputs = if inputsOk then flake.outputs (inputs // { inherit self; }) else { };
      self =
        sourceInfo
        // outputs
        // {
          _type = "flake";
          inherit inputs outputs sourceInfo;
        };
    in
    self;

  resolvedSources = builtins.mapAttrs mkInput sources;
  # Shallow merge is correct: each key is fully resolved before this point.
  # Sub-input overrides (inputs.foo.inputs.bar.follows) are injected into
  # resolvedSources at resolution time via overrideSubSpec, so no deep merge
  # of resolvedSources and resolvedInputs is needed or wanted.
  resolvedInputs = builtins.mapAttrs resolveInput inputs;
  allInputs = resolvedSources // resolvedInputs;
in
allInputs
// {
  __functor =
    allInputs: outputsFn:
    let
      # inputs mirrors a real flake: self is included so modules can access
      # inputs.self.inputs, inputs.self.outputs, and inputs.self.outPath.
      inputs = allInputs // {
        inherit self;
      };
      outputs = outputsFn inputs;
      # self exposes .inputs and .outputs like a real flake self, with all
      # output attributes merged at top level for direct attribute access.
      self = outputs // {
        inherit inputs outputs;
      };
    in
    self;
}
