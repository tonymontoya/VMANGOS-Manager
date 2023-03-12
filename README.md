# vmangos-setup
A script to help automate the installation of a VMaNGOS private server.

# Assumptions

1.  You have an Ubuntu 22.04 server configured with a static IP address.
2.  You have sudo access on this server.
3.  You will be running all three main services on a single machine (Auth, World, and Database)
4.  You are responsible for any additional tuning / configuration that may be required for your needs.
5.  You want to run the 1.12.1 patch version of the game (not a progression server)
6.  You have a local copy of the 1.12.1 client and are able to SCP the /Data directory somehwere to the server.
