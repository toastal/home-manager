{ config, lib, pkgs, ... }:

let
  inherit (config.programs) himalaya;
  tomlFormat = pkgs.formats.toml { };

  enabledEmailAccounts = lib.filterAttrs
    (_: account: "himalaya" ? account && account.himalaya.enable)
    config.accounts.email.accounts;

  needNotmuchFeature = builtins.length
    (lib.filterAttrs (_: account: "notmuch" ? account && account.notmuch.enable)
      enabledEmailAccounts) > 0;

  package = himalaya.package;
  #.override (prev: {
  #  buildFeatures = prev.buildFeatures
  #    ++ lib.optional needNotmuchFeature "notmuch";
  #});

  # attrs util that removes entries containing a null value
  compactAttrs = lib.filterAttrs (_: val: !isNull val);

  # needed for notmuch config, because the DB is here, and not in each
  # account's dir
  maildirBasePath = config.accounts.email.maildirBasePath;

  # make encryption config based on the given home-manager email
  # account TLS config
  mkEncryptionConfig = tls:
    if tls.useStartTls then
      "start-tls"
    else if tls.enable then
      "tls"
    else
      "none";

  # make a himalaya account config based on the given home-manager
  # email account config
  mkAccountConfig = _: account:
    let
      notmuchEnabled = account.notmuch.enable;
      imapEnabled = !isNull account.imap && !notmuchEnabled;
      maildirEnabled = !isNull account.maildir && !notmuchEnabled
        && !imapEnabled;
      smtpEnabled = !isNull account.smtp;
      sendmailEnabled = !smtpEnabled && !isNull account.msmtp;

      globalConfig = {
        email = account.address;
        display-name = account.realName;
        default = account.primary;
        folder.alias = {
          inbox = account.folders.inbox;
          sent = account.folders.sent;
          drafts = account.folders.drafts;
          trash = account.folders.trash;
        };
      };

      signatureConfig =
        lib.optionalAttrs (account.signature.showSignature == "append") {
          # TODO: signature cannot be attached yet:
          # <https://todo.sr.ht/~soywod/pimalaya/27>
          signature = account.signature.text;
          signature-delim = account.signature.delimiter;
        };

      imapConfig = lib.optionalAttrs imapEnabled (compactAttrs {
        backend = "imap";
        imap.host = account.imap.host;
        imap.port = account.imap.port;
        imap.encryption = mkEncryptionConfig account.imap.tls;
        imap.login = account.userName;
        imap.passwd.cmd = builtins.concatStringsSep " " account.passwordCommand;
      });

      maildirConfig = lib.optionalAttrs maildirEnabled (compactAttrs {
        backend = "maildir";
        maildir.root-dir = account.maildir.absPath;
      });

      notmuchConfig = lib.optionalAttrs notmuchEnabled (compactAttrs {
        backend = "notmuch";
        notmuch.database-path = maildirBasePath;
      });

      smtpConfig = lib.optionalAttrs smtpEnabled (compactAttrs {
        message.send.backend = "smtp";
        smtp.host = account.smtp.host;
        smtp.port = account.smtp.port;
        smtp.encryption = mkEncryptionConfig account.smtp.tls;
        smtp.login = account.userName;
        smtp.passwd.cmd = builtins.concatStringsSep " " account.passwordCommand;
      });

      sendmailConfig = lib.optionalAttrs sendmailEnabled {
        message.send.backend = "sendmail";
        sendmail.cmd = "${pkgs.msmtp}/bin/msmtp";
      };

      config = lib.attrsets.mergeAttrsList [
        globalConfig
        signatureConfig
        imapConfig
        maildirConfig
        notmuchConfig
        smtpConfig
        sendmailConfig
      ];

    in lib.recursiveUpdate config account.himalaya.settings;

in {
  meta.maintainers = with lib.hm.maintainers; [ soywod toastal ];

  options = {
    programs.himalaya = {
      enable = lib.mkEnableOption "the email client Himalaya CLI";
      package = lib.mkPackageOption pkgs "himalaya" { };
      settings = lib.mkOption {
        type = lib.types.submodule { freeformType = tomlFormat.type; };
        default = { };
        description = ''
          Himalaya CLI global configuration.
          See <https://pimalaya.org/himalaya/cli/latest/configuration/index.html#global-configuration> for supported values.
        '';
      };
    };

    services.himalaya-watch = {
      enable = lib.mkEnableOption
        "the email client Himalaya CLI envelopes watcher service";

      environment = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = { };
        example = lib.literalExpression ''
          {
            "PASSWORD_STORE_DIR" = "~/.password-store";
          }
        '';
        description = ''
          Extra environment variables to be exported in the service.
        '';
      };

      settings.account = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        example = "personal";
        description = ''
          Name of the account the watcher should be started for.
          If no account is given, the default one is used.
        '';
      };
    };

    accounts.email.accounts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.himalaya = {
          enable = lib.mkEnableOption
            "the email client Himalaya CLI for this email account";
          settings = lib.mkOption {
            type = lib.types.submodule { freeformType = tomlFormat.type; };
            default = { };
            description = ''
              Himalaya CLI configuration for this email account.
              See <https://pimalaya.org/himalaya/cli/latest/configuration/index.html#account-configuration> for supported values.
            '';
          };
        };
      });
    };
  };

  config = lib.mkIf himalaya.enable {
    home.packages = [ package ];

    xdg.configFile."himalaya/config.toml".source = let
      accountsConfig = lib.mapAttrs mkAccountConfig enabledEmailAccounts;
      globalConfig = compactAttrs himalaya.settings;
      allConfig = globalConfig // accountsConfig;
    in tomlFormat.generate "himalaya-config.toml" allConfig;

    systemd.user.services = let
      inherit (config.services.himalaya-watch) enable environment settings;
      optionalArg = key:
        if (key ? settings && !isNull settings."${key}") then
          [ "--${key} ${settings."${key}"}" ]
        else
          [ ];
    in {
      himalaya-watch = lib.mkIf enable {
        Unit = {
          Description = "Email client Himalaya CLI envelopes watcher service";
          After = [ "network.target" ];
        };
        Install = { WantedBy = [ "default.target" ]; };
        Service = {
          ExecStart = lib.concatStringsSep " "
            ([ "${package}/bin/himalaya" "envelopes" "watch" ]
              ++ optionalArg "account");
          ExecSearchPath = "/bin";
          Environment =
            lib.mapAttrsToList (key: val: "${key}=${val}") environment;
          Restart = "always";
          RestartSec = 10;
        };
      };
    };
  };
}
