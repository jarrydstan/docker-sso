# docker‑sso

Self-hosted **Authentik** identity provider stack deployed via Docker Compose.

## What It Deploys

* **Authentik server** - handles user authentication & SSO (SAML/OIDC protocols)
* **Redis** - caching store for Authentik
* **PostgreSQL** - primary database for Authentik
* **Authentik worker** - manages outposts and background tasks

Customizable and brandable via `.env`, media, CSS, and override files.

## Usage

1. Clone the repo.
2. Copy and edit environment variables:

   ```bash
   cp example.env .env
   ```

   * Set values such as database credentials and Authentik configuration.
3. Launch services:

   ```bash
   docker compose up -d
   ```
4. Access the Authentik web interface:

   * Default HTTP port: `9000`
   * Default HTTPS port: `9443` (if enabled via `.env`)
5. Create user accounts and policies within the Authentik UI.

## ⚙️ Customizing

* Use `docker-compose.override.yaml` to add or modify services.
* Customize branding:

  * `media/` for uploaded assets
  * `css/`, `images/` folders for styling and theme

## At-a-Glance

| File / Folder                  | Purpose                                                   |
| ------------------------------ | --------------------------------------------------------- |
| `docker-compose.yaml`          | Defines core containers (Postgres, Redis, server, worker) |
| `example.env` / `.env`         | Environment variables for setup and runtime               |
| `docker-compose.override.yaml` | Optional overrides or extensions                          |
| `media/`, `css/`, `images/`    | Custom branding and assets                                |

