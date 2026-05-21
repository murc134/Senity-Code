---
name: include-git-repository
description: Klont ein Git-Repository (GitHub, GitLab, Gitea, generisches SSH/HTTPS) in /workspace/projects/<name>, sodass es ueber den /workspace-Mount automatisch persistent auf dem Host liegt. Wird auch automatisch vorgeschlagen, wenn der Nutzer eine Git-URL in den Chat postet.
---

# include-git-repository

Klont ein Git-Repository **innerhalb** des Senity-Workspace nach
`/workspace/projects/<name>`. Da `/workspace` direkt auf
`<repo>/workspace/` auf dem Host gemountet ist, liegt der Klon automatisch
persistent unter `workspace/projects/<name>` im Projekt-Verzeichnis. Es
ist **kein Neustart** des Containers noetig.

## Aufruf

```
/include-git-repository <git-url> [--name <ziel-name>] [--branch <branch>]
```

- `<git-url>`: HTTPS oder SSH-URL eines Git-Repos.
  - `https://github.com/<owner>/<repo>.git`
  - `git@github.com:<owner>/<repo>.git`
  - `https://gitlab.com/<owner>/<repo>.git`
  - `ssh://git@git.senity.ai:2200/<owner>/<repo>.git`
  - `https://gitea.example.com/<owner>/<repo>.git`
- `--name <ziel-name>` (optional): Ziel-Verzeichnis unter
  `workspace/projects/`. Default: Basename der URL ohne `.git`.
- `--branch <branch>` (optional): konkreter Branch (Default: Remote-HEAD).

## Verhalten

1. URL parsen, `<name>` ableiten (`--name` schlaegt URL-Basename).
2. Ziel `/workspace/projects/<name>` pruefen:
   - **existiert nicht** -> `git clone`.
   - **existiert + ist Git-Repo** -> Nutzer fragen: pull / neu klonen / abbrechen.
     Default: pull.
   - **existiert + ist KEIN Git-Repo** -> abbrechen.
3. Bei Erfolg ausgeben, dass der Klon unter `workspace/projects/<name>`
   auf dem Host und `/workspace/projects/<name>` im Container liegt.

## Proaktiver Trigger

Wenn der Nutzer **irgendwo im Chat** eine Git-URL postet
(`github.com`, `gitlab.com`, `git.senity.ai`, generische `*.git`-Endungen
oder klare `ssh://git@…`-URLs), soll Claude proaktiv vorschlagen,
diesen Skill zu nutzen, ohne ihn ungefragt auszufuehren:

> "Soll ich dieses Repo nach `workspace/projects/<name>` klonen?
> (Aufruf: `/include-git-repository <url>`)"

Erst wenn der Nutzer zustimmt oder den Skill explizit aufruft, wird
geklont.

## Beispiele

```
/include-git-repository https://github.com/senity/example.git
# -> workspace/projects/example  (im Container: /workspace/projects/example)

/include-git-repository git@github.com:senity/api.git --name api-v2
# -> workspace/projects/api-v2

/include-git-repository ssh://git@git.senity.ai:2200/senity/sdrv5.git --branch dev
# -> workspace/projects/sdrv5  (Branch dev)
```

## Constraints

- **Nie** etwas oberhalb von `/workspace/projects/` schreiben.
- **Nie** `.bindings` anfassen (der Launcher verwaltet den Block selbst).
- Existierende Inhalte unter `/workspace/projects/<name>` ohne Nutzer-OK
  nicht ueberschreiben.
- Bei Auth-Fehlern (Permission denied, etc.): klar melden, **kein**
  automatischer Retry mit anderem Key.

## Warum so?

`workspace/projects/<name>` liegt im bereits gemounteten `/workspace`,
also brauchen wir weder einen extra Docker-Mount, noch eine Konfig-Datei,
noch einen Container-Neustart. Stateless: der Skill macht nichts ausser
`git clone` bzw. `git pull`.
