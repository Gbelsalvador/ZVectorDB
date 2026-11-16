# ZvectorDB

Base de données vectorielle expérimentale et moteur de recherche textuelle écrit en Zig 0.16.

## Démarrer la CLI

Depuis la racine du projet:

```sh
zig build run
```

La CLI utilise des couleurs ANSI pour distinguer l'invite, les résultats, les messages d'erreur et les confirmations. Dans Windows Terminal, le mode ANSI est activé automatiquement.

La CLI interactive indexe les documents et les classe avec BM25. Les documents et les vecteurs sont enregistrés automatiquement dans `zvectordb.db` après chaque insertion, puis restaurés au prochain lancement:

```text
zvectordb> add Zig est un langage de programmation système
zvectordb> add ZvectorDB recherche des documents avec BM25
zvectordb> search langage programmation
zvectordb> list
zvectordb> stats
zvectordb> quit
```

Commandes texte: `add <texte>`, `update <id> <nouveau texte>`, `delete <id>`, `search <requête>`, `search-and <mot1> <mot2>`, `index`, `list`, `stats`, `help`, `quit`. Après suppression, les documents suivants sont renumérotés.

La session expose aussi l'index vectoriel:

```text
zvectordb> dimension 3
zvectordb> vadd 1,0,0
zvectordb> vadd 0.9,0.1,0
zvectordb> vupdate 0 1,0.1,0
zvectordb> vdelete 1
zvectordb> vsearch 1,0,0
zvectordb> hsearch 1,0,0
zvectordb> quantize 0.25,-0.5,1
zvectordb> train langage 100
```

`vsearch` fait une recherche exacte par similarité cosinus. `hsearch` exerce HNSW, mais reconstruit son graphe à chaque requête: c'est une commande de démonstration, pas encore une configuration persistante/performante. `quantize` affiche les valeurs INT8 et le facteur d'échelle.

`vupdate <id> <csv>` modifie un vecteur et `vdelete <id>` le supprime. Les vecteurs suivants sont renumérotés après suppression.

`train <mot> [époques]` entraîne un modèle Word2Vec sur les documents et affiche les cinq voisins du mot. Le modèle Word2Vec reste temporaire; les documents et les vecteurs de la CLI sont conservés dans `zvectordb.db`, dans le répertoire courant. Le stockage WAL/snapshot et mmap existent comme modules expérimentaux séparés.
