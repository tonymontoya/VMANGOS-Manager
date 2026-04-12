# vmangos-setup

A script to automate the installation of a VMaNGOS private World of Warcraft Classic (1.12.1) server on Ubuntu 22.04 LTS.

## What is VMaNGOS?

VMaNGOS is an independent continuation of the Elysium/LightsHope codebases, focused on delivering the most complete and accurate Vanilla WoW content progression system. It supports multiple patch versions from 1.2 through 1.12.1.

## Prerequisites

1. **Ubuntu 22.04 LTS Server** (fresh installation recommended)
2. **Static IP address** configured
3. **Root/sudo access**
4. **WoW 1.12.1.5875 client** - You need a copy of the game client's `/Data` folder
5. **Minimum 2 CPU cores and 4GB RAM** (more RAM recommended for faster compilation)

## Quick Start

1. Upload your WoW 1.12.1 client's `/Data` folder to the server
2. Download and run the script:

```bash
wget https://raw.githubusercontent.com/YOUR_USERNAME/vmangos-setup/main/vmangos_setup.sh
sudo bash vmangos_setup.sh
```

3. Follow the interactive prompts to configure:
   - Installation directory
   - Database names and credentials
   - OS user to run the server

4. After installation, update your WoW client's `realmlist.wtf`:
```
set realmlist YOUR_SERVER_IP
```

## What the Script Does

1. **Installs Dependencies** - Required packages for compilation and runtime
2. **Downloads Source** - Clones the VMaNGOS core and database repositories
3. **Compiles** - Builds the auth server, world server, and extractor tools
4. **Extracts Game Data** - Processes client data (maps, vmaps, mmaps, DBC files)
5. **Sets Up Database** - Creates databases, users, and imports world data
6. **Configures** - Updates server configuration files with your settings
7. **Creates Services** - Sets up systemd services for auto-start

## Post-Installation

### Starting the Servers
```bash
sudo systemctl start auth    # Start auth server
sudo systemctl start world   # Start world server
```

### Checking Status
```bash
sudo systemctl status auth
sudo systemctl status world
```

### Viewing Logs
```bash
sudo journalctl -u auth -f
sudo journalctl -u world -f
```

### Server Console
The world server runs with a console accessible via:
```bash
sudo screen -r  # or attach to tty3
```

## Directory Structure

```
/opt/mangos/              # Default installation root
├── source/               # VMaNGOS source code
├── db/                   # Database files
├── build/                # Build directory
├── run/                  # Compiled binaries and configs
│   ├── bin/              # Server executables
│   │   └── 5875/         # Client data (dbc, maps, vmaps, mmaps)
│   └── etc/              # Configuration files
└── logs/                 # Log files
    ├── mangosd/
    ├── realmd/
    └── honor/
```

## Default Database Names

- `auth` - Account and realm information
- `world` - Game world data (creatures, quests, spells, etc.)
- `characters` - Character data
- `logs` - Server logs

## Troubleshooting

### Compilation Issues
- Ensure you have at least 4GB RAM (swap can help)
- For limited RAM, use fewer parallel jobs: edit `make -j $CPU` to `make -j 1`

### Database Connection Issues
- Verify MariaDB is running: `sudo systemctl status mariadb`
- Check credentials in `/opt/mangos/run/etc/mangosd.conf` and `realmd.conf`

### Client Connection Issues
- Verify `realmlist.wtf` points to your server IP
- Check firewall settings: ports 3724 (auth) and 8085 (world) need to be open
- Verify the realmlist table: `mysql auth -e "SELECT * FROM realmlist;"`

## Security Considerations

1. **Firewall**: Limit access to MySQL port (3306) to trusted IPs only
2. **Database**: Run `mysql_secure_installation` after setup
3. **Updates**: Keep your server updated with the latest VMaNGOS commits

## Resources

- [VMaNGOS Core](https://github.com/vmangos/core)
- [VMaNGOS Database](https://github.com/brotalnia/database)
- [VMaNGOS Wiki](https://github.com/vmangos/wiki/wiki)

## Disclaimer

This script is for educational purposes. Running a private WoW server may violate Blizzard's Terms of Service. Use at your own risk.
