{ pkgs }:

{
  name = "wechat-snapshot-read-only";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ ../system/wechat-snapshot-bridge.nix ];

      users.groups = {
        hermes-user2 = { };
        vboxusers = { };
      };
      users.users = {
        user = {
          isNormalUser = true;
          extraGroups = [ "vboxusers" ];
        };
        user2 = {
          isNormalUser = true;
          extraGroups = [ "hermes-user2" ];
        };
      };

      services.wechatSnapshotBridge = {
        enable = true;
        enableTimer = false;
      };

      systemd.services.hermes-user2 = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          User = "user2";
          Group = "hermes-user2";
          ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
      };

      environment.systemPackages = [ pkgs.sqlite ];
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        "sqlite3 /tmp/source.db \""
        "CREATE TABLE meta(value INTEGER); INSERT INTO meta VALUES(41);"
        "CREATE TABLE contacts(value); CREATE TABLE groups(value);"
        "CREATE TABLE group_members(value); CREATE TABLE chats(value);"
        "CREATE TABLE messages(value); CREATE TABLE media(value);"
        "CREATE TABLE contact_labels(value); CREATE TABLE biz_info(value);"
        "CREATE TABLE voices(value); CREATE TABLE sessions(value);\""
    )
    machine.succeed(
        "wechat-snapshot publish --source /tmp/source.db "
        "--destination /var/lib/hermes-user2-wechat --owner root "
        "--group hermes-user2 --retain 3"
    )
    machine.succeed(
        "runuser -u user2 -- sqlite3 "
        "'file:/var/lib/hermes-user2-wechat/current/snapshot.db?mode=ro&immutable=1' "
        "'SELECT value FROM meta' | grep -Fx 41"
    )
    machine.fail(
        "runuser -u user2 -- sqlite3 "
        "/var/lib/hermes-user2-wechat/current/snapshot.db "
        "'INSERT INTO meta VALUES(42)'"
    )
    machine.succeed(
        "test \"$(stat -c '%a %U %G' "
        "/var/lib/hermes-user2-wechat/current/snapshot.db)\" "
        "= '440 root hermes-user2'"
    )
    machine.succeed(
        "systemctl show hermes-user2.service -p ReadOnlyPaths --value "
        "| grep -F /var/lib/hermes-user2-wechat"
    )
    machine.succeed(
        "runuser -u user2 -- sh -c "
        "'test ! -r /var/lib/wechat-snapshot-publisher/id_ed25519'"
    )
    machine.succeed("runuser -u user2 -- id -nG | grep -vw vboxusers")
    machine.succeed(
        "test \"$(systemctl show wechat-exporter-vm.service -p User --value)\" = user"
    )
    machine.succeed(
        "systemctl cat wechat-exporter-vm.service "
        "| grep -F '/run/wrappers/bin/VBoxHeadless --startvm wechat-exporter --vrde config'"
    )
    machine.succeed(
        "systemctl show wechat-exporter-vm.service -p DeviceAllow --value "
        "| grep -F '/dev/vboxdrv rw'"
    )
    machine.succeed(
        "wechat-vmctl 2>&1 | grep -F "
        "'bridge {enable|disable|status}'"
    )
    machine.succeed(
        "wechat-vmctl 2>&1 | grep -F "
        "'deploy EXPORTER_SOURCE|rollback|release-status'"
    )
    machine.succeed(
        "systemctl cat wechat-exporter-vm.service "
        "| grep -F 'wechat-vm-configure'"
    )
  '';
}
