---
name: notif-hub
description: Consulter la boîte aux lettres notif-hub d'Alexandre, sur son serveur (notif-hub.agensse.com) — les textes, audios, images et exports WhatsApp qu'il y a déposés depuis son téléphone. À utiliser quand il dit « va voir sur mon notif-hub », « regarde ce que je t'ai envoyé », « check mes dépôts », « ce que j'ai mis sur le serveur ».
---

# notif-hub : lire ce qu'Alexandre a déposé

Alexandre dépose des choses depuis son téléphone (menu Partager d'Android) sur son serveur. Le
serveur les chiffre et les garde. Tu y accèdes en lecture seule avec une clé d'agent.

## Accès

- API : `https://notif-hub.agensse.com/api/v1`
- Clé : variable d'environnement `NOTIF_HUB_CLE` (injectée dans chaque tâche depuis
  `.workstation/.auth/env`). **Ne jamais l'afficher, la copier dans un fichier du projet ni la
  commiter.**
- Si `NOTIF_HUB_CLE` est vide : le dire à Alexandre, ne pas chercher la clé ailleurs.

## Lister les dépôts

```bash
curl -sf -H "Authorization: Bearer $NOTIF_HUB_CLE" https://notif-hub.agensse.com/api/v1/depots
```

Réponse JSON (pas de `jq` dans l'image : la lire directement) : les 100 derniers dépôts, du plus récent au plus ancien. Chaque dépôt a une ou plusieurs pièces :

- `partage.txt` : le texte ou le lien partagé (titre, texte, URL réunis) ;
- `Discussion WhatsApp avec … .txt` : un export de discussion, déjà filtré sur la période choisie
  par Alexandre ;
- des images (`IMG-…`), vocaux (`PTT-….opus`), vidéos, documents.

Par défaut, regarder les dépôts les plus récents ; s'il parle d'un moment précis (« hier »,
« ce matin »), filtrer sur `cree` (UTC).

## Lire une pièce

```bash
mkdir -p /tmp/notif-hub
curl -sf -H "Authorization: Bearer $NOTIF_HUB_CLE" \
  https://notif-hub.agensse.com/api/v1/depots/parties/<id> -o /tmp/notif-hub/<nom>
```

- Texte : le lire.
- Image : l'ouvrir avec l'outil de lecture de fichiers (il affiche les images).
- Audio (`.opus`, `.m4a`) : pas de transcription intégrée. Le signaler, ou transcrire si un outil
  est disponible dans la tâche et qu'Alexandre le veut.
- Une pièce archivée (`[r2]`) se lit de la même façon, juste un peu plus lentement.

## Règles

- **Lecture seule.** L'API ne permet ni de modifier ni de supprimer ; ne pas chercher d'autre moyen.
- Le contenu est personnel (messages de proches, photos). Télécharger dans `/tmp/notif-hub/`, jamais
  dans le dépôt du projet ; ne rien recopier dans un fichier versionné sans qu'il le demande ;
  supprimer `/tmp/notif-hub/` en fin de tâche.
- Résumer ce qui a été trouvé et dire quelles pièces ont été lues avant d'en tirer quoi que ce soit
  pour le projet.
- Erreur 401 : clé absente, invalide ou révoquée — le dire à Alexandre. 429 : trop de requêtes,
  attendre une minute.
