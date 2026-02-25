{
  inputs.nixpkgs = { };
  outputs =
    { self, nixpkgs, ... }:
    {
      usedNixpkgs = nixpkgs;
    };
}
