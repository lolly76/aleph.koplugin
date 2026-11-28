**Version de test, pas une version stable.** Aleph 1.3.0 avec la synchro Grimmory (fork lolly76), version 1.3.0-grimmory.4.

## Installer

1. Télécharge `aleph.koplugin.zip` ci-dessous et décompresse-le.
2. Copie le dossier `aleph.koplugin` dans `koreader/plugins/` sur la liseuse (remplace l'ancien s'il existe).
3. Redémarre KOReader.

Sans compte Grimmory, Aleph fonctionne comme avant : rien ne part sur le réseau.

## Brancher Grimmory

1. Dans Aleph : **Réglages > Bibliothèque > Grimmory**, mets l'adresse du serveur (par exemple `http://192.168.1.10:6060`).
2. **Compte Grimmory** : ton identifiant et ton mot de passe du site Grimmory. Aleph crée l'utilisateur KOReader et active la synchro de la progression tout seul.
3. **Synchroniser avec Grimmory maintenant** pour faire correspondre les livres.

## À vérifier

- La progression passe d'un appareil à l'autre (ouvrir un livre propose d'aller plus loin).
- « En pause » et « Terminé » restent tels quels dans Grimmory après une fermeture du livre.
- Les surlignages d'un EPUB apparaissent dans le lecteur web de Grimmory, et inversement, sans ralentir la liseuse.
- Parcourir Grimmory et télécharger un livre.
- Toujours connecté après plus de 2 heures.

## En cas de problème

Envoie le fichier `koreader/crash.log` (les lignes « Aleph ») avec ce que tu faisais.
