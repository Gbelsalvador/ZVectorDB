# ZvectorDB

Base de données vectorielle expérimentale et moteur de recherche textuelle écrit en Zig 0.16.

## Démarrer la CLI

Depuis la racine du projet:

```sh
zig build run
```

La CLI interactive indexe les documents en mémoire et les classe avec BM25:

```text
zvectordb> add Zig est un langage de programmation système
zvectordb> add ZvectorDB recherche des documents avec BM25
zvectordb> search langage programmation
zvectordb> list
zvectordb> stats
zvectordb> quit
```

Commandes texte: `add <texte>`, `search <requête>`, `search-and <mot1> <mot2>`, `index`, `list`, `stats`, `help`, `quit`.

La session expose aussi l'index vectoriel:

```text
zvectordb> dimension 3
zvectordb> vadd 1,0,0
zvectordb> vadd 0.9,0.1,0
zvectordb> vsearch 1,0,0
zvectordb> hsearch 1,0,0
zvectordb> quantize 0.25,-0.5,1
zvectordb> train langage 100
```

`vsearch` fait une recherche exacte par similarité cosinus. `hsearch` exerce HNSW, mais reconstruit son graphe à chaque requête: c'est une commande de démonstration, pas encore une configuration persistante/performante. `quantize` affiche les valeurs INT8 et le facteur d'échelle.

`train <mot> [époques]` entraîne un modèle Word2Vec sur les documents de la session et affiche les cinq voisins du mot. Les documents, modèles et vecteurs restent en mémoire pendant la session. Le stockage WAL/snapshot et mmap existent comme modules expérimentaux, mais ne sont pas reliés à la CLI.
