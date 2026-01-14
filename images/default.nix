{ pkgs, ... }:
with pkgs; {
  home-assistant = (callPackage ./home-automation/home-assistant { }) { };
  fava = (callPackage ./misc/fava { }) { };
}
