# ZvectorDB

Base de données vectorielle expérimentale et moteur de recherche textuelle écrit en Zig 0.16.

## Architecture actuelle

Ce diagramme présente les principaux composants et leurs relations dans le fonctionnement actuel de la CLI:

```mermaid
flowchart LR
    CLI["CLI<br/>main.zig"]
    Engine["Engine<br/>engine.zig"]

    subgraph TEXT["Recherche textuelle"]
        Document["Document<br/>id + contenu"]
        Tokenizer["Tokenizer"]
        InvertedIndex["InvertedIndex<br/>termes et postings"]
        SearchEngine["SearchEngine"]
        BM25["BM25<br/>calcul des scores"]
        SearchResult["SearchResult"]
        SearchEngine -->|"tokenise la requête"| Tokenizer
        SearchEngine -->|"lit les postings et statistiques"| InvertedIndex
        SearchEngine -->|"score les documents"| BM25
        SearchEngine --> SearchResult
    end

    subgraph VECTOR["Recherche vectorielle"]
        VectorIndex["VectorIndex<br/>recherche exacte"]
        HNSW["HNSW<br/>recherche approchée"]
        VectorIndex -->|"vecteurs indexés"| HNSW
    end

    QueryEngine["QueryEngine<br/>planification, fusion RRF,<br/>reranking, top 10"]
    Storage["Storage"]
    Database[("zvectordb.db<br/>documents + vecteurs")]
    Graph[("zvectordb.hnsw<br/>graphe HNSW")]

    CLI --> Engine
    Engine -->|"stocke"| Document
    Engine -->|"indexe le contenu"| Tokenizer
    Tokenizer --> InvertedIndex
    Engine --> SearchEngine
    Engine --> VectorIndex
    Engine --> HNSW
    Engine --> QueryEngine
    SearchResult -->|"candidats BM25"| QueryEngine
    HNSW -->|"candidats vectoriels"| QueryEngine
    QueryEngine -->|"résultats fusionnés"| Engine
    Engine --> Storage
    Storage --> Database
    HNSW --> Graph
```

`Engine` orchestre les opérations et la persistance. Le flux textuel indexe le contenu des documents via `Tokenizer` et `InvertedIndex`; `SearchEngine` applique le scorer `BM25`. Le flux vectoriel utilise `VectorIndex` pour la recherche exacte et HNSW pour la recherche approchée. Pour `query` et `hybrid`, `QueryEngine` planifie les sources, fusionne les candidats et effectue le reranking. Les documents et les vecteurs doivent actuellement avoir des identifiants alignés dans le même ordre pour être fusionnés.

Le type `Document` actuellement utilisé par `Engine` est déclaré dans `engine.zig`; le fichier `src/document.zig` existe mais n'est pas encore relié à ce flux. `src/root.zig` exporte `Engine` comme module Zig. L'API HTTP v1 expose maintenant les opérations de base via une collection default; les utilisateurs peuvent aussi continuer à passer par la CLI. Les composants WAL/snapshot et mmap restent expérimentaux et ne sont pas utilisés par l'Engine de la CLI.

## Démarrer la CLI

Depuis la racine du projet:

```sh
zig build run
```

La CLI utilise des couleurs ANSI pour distinguer l'invite, les résultats, les messages d'erreur et les confirmations. Dans Windows Terminal, le mode ANSI est activé automatiquement.

La CLI délègue l'orchestration à `Engine`, qui réunit documents/BM25, vecteurs/HNSW et query engine tout en conservant `zvectordb.db` et `zvectordb.hnsw`. Le `WalEngine` de bas niveau reste expérimental et n'est pas activé par la CLI. Les documents et les vecteurs sont enregistrés automatiquement après chaque insertion, puis restaurés au prochain lancement:

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
zvectordb> vsearch 1,0,0
zvectordb> hsearch 1,0,0
zvectordb> hybrid langage programmation --vector 1,0,0
zvectordb> query langage programmation --vector 1,0,0
zvectordb> vdelete 1
zvectordb> quantize 0.25,-0.5,1
zvectordb> train langage 100
```

`vsearch` fait une recherche exacte par similarité cosinus. `hsearch` utilise un graphe HNSW conservé en mémoire pendant la session et enregistré dans `zvectordb.hnsw`; il est restauré au prochain lancement et mis à jour avec les opérations vectorielles. `quantize` affiche les valeurs INT8 et le facteur d'échelle.

`hybrid <requête texte> --vector <csv>` lance le query engine avec BM25 et HNSW. Il faut un vecteur par document, dans le même ordre, afin que les identifiants correspondent.

`query <texte> [--vector <csv>]` affiche son plan de recherche (filtres, sources, nombre de candidats, fusion, reranking et limite), puis l'exécute. Il prend jusqu'à 50 candidats par source, fusionne les rangs par RRF, rerank les candidats avec les scores BM25 et cosinus normalisés (poids 50/50 si les deux sources ont des résultats), puis retourne jusqu'à 10 résultats. Sans vecteur de requête, il utilise BM25 seul; sans texte, HNSW seul. Les filtres restent désactivés tant que les documents ne portent pas de métadonnées indexées.

`vupdate <id> <csv>` modifie un vecteur et `vdelete <id>` le supprime. Les vecteurs suivants sont renumérotés après suppression.

`train <mot> [époques]` entraîne un modèle Word2Vec sur les documents et affiche les cinq voisins du mot. Le modèle Word2Vec reste temporaire; les documents et les vecteurs de la CLI sont conservés dans `zvectordb.db`, et le graphe HNSW dans `zvectordb.hnsw`, dans le répertoire courant. Le stockage WAL/snapshot et mmap existent comme modules expérimentaux séparés.

## API HTTP v1

Le serveur HTTP expose le moteur sur `127.0.0.1` (port `8080` par défaut). Lancez-le avec:

```sh
zig build run -- serve [port]
```

Routes disponibles:

| Méthode | Route | Fonction |
|---|---|---|
| `GET` | `/api/v1/collections` | Lister la collection `default` |
| `GET` | `/api/v1/collections/default` | Lire la collection |
| `GET` | `/api/v1/collections/default/documents` | Lister les documents |
| `POST` | `/api/v1/collections/default/documents` | Ajouter `{"content":"..."}` |
| `GET` | `/api/v1/collections/default/documents/{id}` | Lire un document |
| `PUT` | `/api/v1/collections/default/documents/{id}` | Remplacer son contenu |
| `DELETE` | `/api/v1/collections/default/documents/{id}` | Supprimer le document |
| `POST` | `/api/v1/collections/default/search` | Recherche BM25 avec `{"query":"..."}` |

L’API v1 utilise pour l’instant la collection persistante existante. Elle écoute uniquement sur l’interface locale et accepte les requêtes HTTP/1.1 avec un corps JSON limité à 1 Mio.
