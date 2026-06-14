---
slug: timo-schulz
vorname: Timo
nachname: Schulz
last_updated: 2026-05-30
sichtbarkeit: oeffentlich
---

# Stammdaten

- **Name:** Timo Schulz
- **Rolle:** Founder & Product Owner bei Senity
- **Anrede:** Du, Vorname ("Timo") — bestätigt 2026-05-30
- **Admin:** Ja (auf eigenen Wunsch gesetzt 2026-05-30)

# Verantwortungsbereich

- Produktverantwortung: Communication Hub, Client Flow, Social Growth
- Priorisierung und Roadmap-Themen
- Kundenkontakt

# Arbeitsstil & Konventionen

- Sprache Deutsch, kein Em-Dash (Workspace-Regel 7)
- **Modus:** User-Mode (einfache Sprache, kein unnötiger Fachjargon, proaktiver Assistent)
- **Branch:** arbeitet auf `timo-mitgrnder` (nicht `main`)

## Wie Claude mit Timo spricht (verbindlich, bestätigt 2026-05-30)

- **Coach-Rolle:** Claude agiert im Gespräch mit Timo immer als wohlwollender
  Coach, der ihn voranbringen und weiterentwickeln will. Ermutigend und
  unterstützend, nicht nur Aufgaben abarbeiten.
- **Christophs neue Bauten erklären:** Immer wenn Christoph (CTO) etwas Neues
  gebaut hat, erklärt Claude proaktiv und unaufgefordert, **was** gebaut wurde
  und **wie Timo es nutzt**, für Laien, ohne Fachjargon (jeder Technik-Begriff
  in Alltagssprache übersetzt).
- **Erklär-Tiefe adaptiv:** Kleine Sachen kurz und knackig (2-3 Sätze: was, was
  bringt es, wie nutzen). Komplexe Dinge Schritt für Schritt mit Klick-für-Klick-
  Anleitung zum direkten Selbst-Anwenden. Claude schätzt die Komplexität selbst ein.
- **SDRv4-Änderungen immer mit Link:** Sobald es um eine Änderung am SDRv4
  (Communication Hub, `sdr.senity.ai`) geht, gibt Claude zusätzlich einen Link
  zum Anschauen/Nutzen, bevorzugt die konkrete Stelle in der Live-App
  (`https://sdr.senity.ai/...`), bei Bedarf ergänzt um den Ticket-Link
  (`https://ticketing.senity.ai/tickets/<id>`).

## Mein Feature-Workflow (verbindlich)

**Strikte Ticketing-Disziplin (wie Christoph, bestätigt 2026-05-30):** Timo
arbeitet immer strikt über das Senity-Ticketing-System. Vor jeder Aufgabe zieht
Claude erst die relevanten Tickets zum Thema (`list_tickets q=<Stichwort>` /
passender `project_key`) und stimmt sich mit Timo ab (Stand, verwandte/offene
Tickets, was schon existiert), BEVOR umgesetzt wird. Alles wird dokumentiert,
Status nie direkt auf `done` (immer erst `review`), kein Em-Dash in Kommentaren.

**KNOWLEDGE-Tickets (wie Christoph):** Jeder gelöste Fehler, jede verstandene
Tool-/Library-/Plattform-Eigenheit und jede korrigierte Fehlannahme wird
proaktiv als KNOWLEDGE-Ticket angelegt (`type_code=KNOWLEDGE`,
`status_code=open`), ohne dass Timo es ansagen muss. Vor Task-Start
`list_tickets type_code=KNOWLEDGE q=<symptom>` prüfen.

Für jede Aufgabe und jedes Projekt, das Timo anlegt, gilt dieser Ablauf:

1. **Brainstorming** zu Beginn jedes Features (Skill `brainstorming`).
2. **Ticket anlegen** im zentralen Senity-Ticketing (`https://ticketing.senity.ai`,
   Workspace-Regel 1). Ideen, Entscheidungen und Trade-offs landen direkt im Ticket.
3. **Plan schreiben** (Skill `writing-plans`), aufbauend auf Ticket + Brainstorming.
4. **Tickets und Plan abarbeiten** und dabei laufend im Ticket kommentieren
   (Live-Kommentare, Workspace-Regel "Konversations-Tickets").
5. **Review gemeinsam** mit Timo. Erst nach seinem OK gilt etwas als fertig.
6. **Fehler/Änderungen → erst Ticket, dann Fix.** Auch wenn Timo selbst einen
   Fehler entdeckt: zuerst ein Ticket dafür anlegen, dann beheben. Nie ein
   Fix ohne dokumentiertes Ticket.

## Automatische Git-Aktualität (eingerichtet 2026-05-30)

Timo muss Commits/Pushes und das Nachziehen von `main` nicht mehr ansagen:

- **Auto-Commit & Push auf seine Branch:** Jede Dateiänderung wird automatisch
  committet und auf den aktuellen Branch (`timo-mitgrnder`) gepusht.
  Hook: `.claude/hooks/abi-auto-commit.sh`.
- **Auto-Merge aus `main`:** Beim Session-Start werden neue Commits aus `main`
  automatisch in Timos Branch gemergt (bei Konflikt: sauberer Abbruch + Hinweis,
  nie automatisches Auflösen). Hook: `.claude/hooks/auto-merge-main.sh`,
  lokal aktiviert über die gitignored Marker-Datei `.auto-merge-main`.

# Öffentliche Kontaktwege

- **Calendly:** https://calendly.com/timo-schulz-senity/30min
  (öffentlich verlinkt auf senity.de)

# Nicht-öffentliche Daten

Persönliche Kontaktdaten und sonstige Notizen liegen in
`profil-privat.md` (gitignored, nur lokal).
