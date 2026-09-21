---
name: notif-hub
description: Consulter la boîte aux lettres notif-hub d'Alexandre, sur son serveur (notif-hub.agensse.com) — les textes, audios, images et exports WhatsApp qu'il y a déposés depuis son téléphone — et lui poser une question à réponses choisies (oui/non, ok/à voir plus tard…) sur son téléphone. À utiliser quand il dit « va voir sur mon notif-hub », « regarde ce que je t'ai envoyé », « check mes dépôts », « ce que j'ai mis sur le serveur », ou « demande-moi sur mon téléphone / sur notif-hub ».
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

Réponse JSON (pas de `jq` dans l'image : la lire directement) : les 100 derniers dépôts, du plus récent au plus ancien.

Un dépôt sans champ `source` vient d'Alexandre (son téléphone). Un dépôt avec `source` a été
envoyé par un de ses sites (`"source": "odile"`, par exemple) ; son texte est dans `texte.txt`.
Quand il parle de « ce que je t'ai envoyé », ce sont ses dépôts à lui, sans `source`.

Chaque dépôt a une ou plusieurs pièces :

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

## Poser une question à Alexandre

Il reçoit une notification sur son téléphone et choisit une des réponses proposées. À faire
quand il te demande de lui poser la question sur son téléphone ou sur notif-hub, ou quand la
tâche le prévoit.

```bash
curl -sf -H "Authorization: Bearer $NOTIF_HUB_CLE" -H "Content-Type: application/json" \
  -d '{"titre":"Je déploie la nouvelle page ?","corps":"Tests OK, 3 fichiers modifiés.","choix":["Oui","Non"]}' \
  https://notif-hub.agensse.com/api/v1/questions
# → {"id":"…"}
```

- `choix` : 2 à 6 réponses courtes (40 caractères au plus), toutes différentes. Avec 2 réponses,
  il peut répondre directement depuis les boutons de la notification ; au-delà, il doit ouvrir
  l'appli.
- `titre` : la question, courte ; `corps` (facultatif) : le contexte utile pour décider. Rien de
  secret : la notification s'affiche sur l'écran verrouillé.

Attendre la réponse :

```bash
curl -sf -H "Authorization: Bearer $NOTIF_HUB_CLE" \
  "https://notif-hub.agensse.com/api/v1/questions/<id>?attendre=50"
```

La requête patiente jusqu'à 50 s. Tant que `"etat":"attente"`, la relancer. `"etat":"repondue"` :
la réponse choisie est dans `texte` (et son rang dans `reponse`). Il peut répondre des heures plus
tard : si tu ne peux pas attendre, dis-lui que la question est posée et reviens la lire plus tard.
Si la question n'a plus lieu d'être, l'annuler :
`curl -sf -X DELETE -H "Authorization: Bearer $NOTIF_HUB_CLE" https://notif-hub.agensse.com/api/v1/questions/<id>`.

## Règles

- **Dépôts en lecture seule.** L'API ne permet ni de modifier ni de supprimer un dépôt ; ne pas chercher d'autre moyen.
- Le contenu est personnel (messages de proches, photos). Télécharger dans `/tmp/notif-hub/`, jamais
  dans le dépôt du projet ; ne rien recopier dans un fichier versionné sans qu'il le demande ;
  supprimer `/tmp/notif-hub/` en fin de tâche.
- Résumer ce qui a été trouvé et dire quelles pièces ont été lues avant d'en tirer quoi que ce soit
  pour le projet.
- Erreur 401 : clé absente, invalide ou révoquée — le dire à Alexandre. 429 : trop de requêtes,
  attendre une minute.
