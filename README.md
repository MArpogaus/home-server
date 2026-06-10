# SecureBlue Deployment (Private)

Dieses Repository enthält private Konfigurationen und Secrets für das SecureBlue-Deployment.

## ⚠️ WICHTIG

**Dieses Repository ist PRIVATE und darf nicht öffentlich sein!**

Es enthält:
- SSH-Keys für den VM-Zugriff
- Datenbank-Passwörter
- GHCR-Authentifizierung
- Domänen-spezifische Konfigurationen

## Struktur

```
deployment-private/
├── secrets/
│   ├── vars.yml           # Private Variablen (nicht committen!)
│   └── auth.json          # Podman GHCR Login
├── inventory/
│   └── hosts.ini          # Host-Konfiguration
├── ssh/
│   └── coreos_key         # SSH-Key für VM
└── deploy.sh              # Deployment-Skript
```

## Einrichtung

1. **Repository klonen** (nur auf vertrauenswürdigen Maschinen):
   ```bash
   git clone git@github.com:your-username/deployment-private.git
   cd deployment-private
   ```

2. **Secrets konfigurieren**:
   ```bash
   cp secrets/vars.yml.example secrets/vars.yml
   # Bearbeite vars.yml mit deinen Werten
   ```

3. **SSH-Key einrichten**:
   ```bash
   ssh-keygen -t ed25519 -f ssh/coreos_key -N ""
   chmod 600 ssh/coreos_key
   ```

4. **GHCR Login**:
   ```bash
   echo $GHCR_TOKEN | podman login ghcr.io -u $GHCR_USERNAME --password-stdin
   podman login ghcr.io -u $GHCR_USERNAME --password-stdin
   # auth.json wird automatisch erstellt
   ```

## Deployment

```bash
./deploy.sh
```

Das Skript führt folgende Schritte aus:
1. Validiert Secrets
2. Startet VM (falls nötig)
3. Führt Ansible Playbook aus
4. Aktiviert Quadlet Services
5. Validiert Deployment

## Secrets Management

- **NIEMALS** echte Secrets committen
- Nutze `secrets/vars.yml` für lokale Entwicklung
- Für CI/CD: GitHub Secrets verwenden
- `.gitignore` schützt vor versehentlichem Commit

## Backup

Regelmäßige Backups von `/var/services/snapshots` auf externen Speicher.

## Troubleshooting

Siehe `../ansible-base/Agent.md` für detaillierte Fehlerbehebung.
