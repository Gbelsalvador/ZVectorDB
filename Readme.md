# PROPOSITION DE SUJET DE PROJET DE FIN D'ANNÉE

## 1. Intitulé du sujet

**Conception, implémentation et évaluation comparative d'un moteur de recherche vectorielle haute performance en Zig pour les systèmes de Retrieval-Augmented Generation (RAG)**

**Nom du projet :** KÓTÀA Vector Engine

---

## 2. Domaine

* Intelligence artificielle
* Recherche d'information
* Bases de données vectorielles
* Retrieval-Augmented Generation (RAG)
* Optimisation des performances
* Programmation système
* Calcul parallèle et SIMD

---

## 3. Contexte et justification

L'évolution récente des modèles de langage de grande taille (LLM) a favorisé le développement de nouvelles applications basées sur l'intelligence artificielle générative. Cependant, les modèles de langage présentent certaines limites, notamment leur connaissance limitée des données privées ou récentes et leur capacité à produire des informations incorrectes ou obsolètes.

L'approche **Retrieval-Augmented Generation (RAG)** constitue une solution permettant d'améliorer la pertinence des réponses générées par les modèles de langage en leur fournissant des informations provenant de sources externes.

Dans une architecture RAG, les documents sont généralement transformés en représentations vectorielles appelées *embeddings*. Ces vecteurs sont ensuite stockés dans une base de données vectorielle afin de permettre la recherche rapide des documents les plus pertinents pour une requête donnée.

La performance du moteur de recherche vectorielle constitue donc un élément essentiel de l'efficacité globale d'un système RAG. Des solutions telles que FAISS, ChromaDB, Qdrant ou Milvus proposent déjà différentes approches pour la recherche de similarité vectorielle. Toutefois, ces solutions présentent différents compromis en matière de latence, de consommation mémoire, de précision, de persistance, de recherche hybride et de mise à jour des index.

Le langage **Zig**, grâce à son contrôle explicite de la mémoire, ses possibilités d'optimisation bas niveau, sa compilation native et son support des opérations vectorielles, constitue une technologie intéressante pour explorer la conception d'un moteur de recherche vectorielle performant.

Ce projet propose donc la conception et l'implémentation de **KÓTÀA Vector Engine**, un moteur de recherche vectorielle développé en Zig, dont les performances seront évaluées expérimentalement et comparées à celles de solutions existantes.

---

## 4. Problématique

Les systèmes RAG nécessitent une récupération rapide et pertinente des informations afin de fournir au modèle de langage un contexte adapté à la génération de réponses.

Cependant, lorsque le nombre de vecteurs augmente, la recherche de similarité devient coûteuse en temps de calcul et en ressources mémoire. Les systèmes doivent également gérer plusieurs contraintes telles que la précision de la recherche, la latence, le débit de requêtes, la persistance des données et les mises à jour des index.

La problématique principale de ce projet est donc la suivante :

> **Comment concevoir et implémenter en Zig un moteur de recherche vectorielle capable d'offrir un compromis efficace entre performance, précision, consommation mémoire et flexibilité pour les applications RAG, tout en évaluant expérimentalement ses performances par rapport à des solutions existantes ?**

---

## 5. Question de recherche

La question principale de recherche est :

> **Dans quelle mesure l'utilisation du langage Zig et de techniques d'optimisation bas niveau telles que SIMD, HNSW et la quantification peut-elle améliorer les performances d'un moteur de recherche vectorielle destiné aux systèmes RAG ?**

Les questions secondaires sont :

1. Quel impact l'utilisation de SIMD a-t-elle sur la vitesse de calcul des similarités vectorielles ?
2. Dans quelle mesure l'index HNSW permet-il de réduire la latence de recherche par rapport à une recherche exhaustive ?
3. Quel compromis existe-t-il entre précision de recherche et performance lors de l'utilisation de méthodes de quantification ?
4. Quel est l'impact de la consommation mémoire sur les performances du moteur ?
5. Dans quels scénarios le moteur proposé peut-il être compétitif face à des solutions existantes telles que FAISS ou ChromaDB ?
6. Comment intégrer efficacement la recherche vectorielle, la recherche lexicale et les filtres de métadonnées dans une architecture adaptée aux systèmes RAG ?

---

## 6. Hypothèse de recherche

L'hypothèse principale est la suivante :

> **L'utilisation de Zig, combinée à une gestion mémoire contrôlée et à des techniques d'optimisation telles que SIMD, HNSW, la quantification et le traitement parallèle, permettrait de concevoir un moteur de recherche vectorielle offrant de bonnes performances en termes de latence, de débit et de consommation mémoire pour certains scénarios d'utilisation des systèmes RAG.**

L'objectif n'est pas de supposer que le moteur sera systématiquement supérieur aux solutions existantes, mais d'identifier expérimentalement les scénarios dans lesquels son architecture peut présenter des avantages.

---

# 7. Objectif général

L'objectif général de ce projet est de :

> **Concevoir, implémenter et évaluer un moteur de recherche vectorielle haute performance en Zig, nommé KÓTÀA Vector Engine, destiné à être utilisé comme composant de recherche dans des systèmes RAG.**

---

# 8. Objectifs spécifiques

Le projet vise spécifiquement à :

1. Étudier les principes fondamentaux de la recherche vectorielle et des systèmes RAG.

2. Étudier les principales structures d'indexation utilisées dans les systèmes de recherche vectorielle.

3. Concevoir une architecture modulaire pour un moteur de recherche vectorielle développé en Zig.

4. Implémenter un moteur de recherche vectorielle basé initialement sur la recherche exhaustive (*Flat Search*).

5. Implémenter des fonctions optimisées de calcul de similarité vectorielle, notamment la similarité cosinus et la distance euclidienne.

6. Exploiter les possibilités de calcul SIMD afin d'accélérer les opérations mathématiques sur les vecteurs.

7. Implémenter un mécanisme de recherche Top-K optimisé.

8. Implémenter un index de recherche approximative basé sur HNSW.

9. Étudier et intégrer des techniques de quantification des vecteurs afin de réduire la consommation mémoire.

10. Concevoir un système de stockage persistant permettant de sauvegarder et de restaurer les index.

11. Étudier l'utilisation de la mémoire mappée (*memory-mapped files*) pour améliorer la gestion des grands index.

12. Ajouter un mécanisme de filtrage basé sur les métadonnées.

13. Étudier l'intégration d'une recherche hybride combinant recherche vectorielle et recherche lexicale.

14. Développer une interface permettant l'intégration du moteur avec des applications externes.

15. Évaluer expérimentalement les performances de KÓTÀA Vector Engine.

16. Comparer les résultats obtenus avec des solutions existantes telles que FAISS et ChromaDB.

17. Identifier les forces, les limites et les scénarios d'utilisation dans lesquels l'approche proposée est pertinente.

---

# 9. Méthodologie

Le projet sera réalisé selon les étapes suivantes.

### Étape 1 : Étude bibliographique

Une étude sera menée sur :

* les systèmes RAG ;
* les embeddings ;
* la recherche de similarité ;
* les bases de données vectorielles ;
* les index ANN (*Approximate Nearest Neighbor*) ;
* HNSW ;
* SIMD ;
* la quantification vectorielle ;
* la recherche hybride ;
* les techniques de benchmarking.

---

### Étape 2 : Analyse des solutions existantes

Les solutions suivantes seront étudiées :

* FAISS ;
* ChromaDB ;
* Qdrant ;
* éventuellement Milvus selon les ressources disponibles.

L'étude portera notamment sur :

* l'architecture ;
* les méthodes d'indexation ;
* les performances ;
* la consommation mémoire ;
* la persistance ;
* les capacités de filtrage ;
* les possibilités de recherche hybride.

---

### Étape 3 : Conception de KÓTÀA Vector Engine

Une architecture modulaire sera conçue autour des composants suivants :

```text
API
 │
 ▼
Query Processor
 │
 ├── Vector Search
 │
 ├── Metadata Filter
 │
 └── Hybrid Search
 │
 ▼
Index Engine
 │
 ├── Flat Index
 │
 ├── HNSW
 │
 └── Quantization
 │
 ▼
SIMD Compute Engine
 │
 ▼
Storage Engine
 │
 ├── WAL
 ├── Segments
 └── Memory Mapping
```

---

### Étape 4 : Implémentation

Le moteur sera progressivement développé en Zig selon les phases suivantes :

**Phase 1 :**

* représentation des vecteurs ;
* calcul de distance ;
* recherche exhaustive ;
* Top-K.

**Phase 2 :**

* optimisation SIMD ;
* parallélisation ;
* optimisation de la gestion mémoire.

**Phase 3 :**

* implémentation de HNSW ;
* recherche approximative ;
* réglage du compromis vitesse/précision.

**Phase 4 :**

* quantification ;
* stockage persistant ;
* memory mapping.

**Phase 5 :**

* métadonnées ;
* filtrage ;
* recherche hybride.

**Phase 6 :**

* API ;
* intégration avec une application RAG.

---

# 10. Architecture technique envisagée

Le système sera organisé autour de plusieurs modules :

### Vector Core

Responsable de :

* la représentation des vecteurs ;
* le calcul des distances ;
* la similarité cosinus ;
* les opérations SIMD.

### Index Engine

Responsable de :

* Flat Index ;
* HNSW ;
* recherche ANN ;
* Top-K.

### Quantization Engine

Responsable de :

* FP32 ;
* FP16 ;
* INT8 ;
* réduction de la consommation mémoire.

### Storage Engine

Responsable de :

* persistance ;
* WAL ;
* segments ;
* snapshots ;
* memory mapping.

### Metadata Engine

Responsable de :

* stockage des métadonnées ;
* filtrage ;
* indexation secondaire.

### Search Engine

Responsable de :

* recherche vectorielle ;
* recherche hybride ;
* fusion des résultats ;
* reranking.

### API Layer

Responsable de l'intégration avec :

* applications Python ;
* FastAPI ;
* Django ;
* applications RAG.

---

# 11. Technologies envisagées

| Technologie | Utilisation                         |
| ----------- | ----------------------------------- |
| Zig         | Développement du moteur principal   |
| SIMD        | Accélération des calculs vectoriels |
| HNSW        | Recherche vectorielle approximative |
| INT8 / FP16 | Quantification                      |
| mmap        | Accès aux index persistants         |
| HTTP / gRPC | Communication avec les applications |
| Python      | Benchmark et intégration RAG        |
| FastAPI     | API de démonstration                |
| FAISS       | Référence comparative               |
| ChromaDB    | Référence comparative               |

---

# 12. Protocole d'évaluation

Les performances seront évaluées sur plusieurs volumes de données, par exemple :

* 10 000 vecteurs ;
* 100 000 vecteurs ;
* 1 million de vecteurs ;
* éventuellement 10 millions de vecteurs selon les ressources matérielles disponibles.

Plusieurs dimensions pourront être étudiées :

* 128 ;
* 384 ;
* 768 ;
* 1536.

Les métriques étudiées seront :

### Performance

* Latence moyenne ;
* Latence P50 ;
* Latence P95 ;
* Latence P99 ;
* QPS (*Queries Per Second*).

### Précision

* Recall@1 ;
* Recall@10 ;
* Recall@100.

### Ressources

* Consommation RAM ;
* Taille de l'index ;
* Temps de construction de l'index ;
* Temps d'insertion ;
* Temps de mise à jour.

Les résultats de KÓTÀA Vector Engine seront comparés à ceux des solutions sélectionnées dans des conditions matérielles et expérimentales aussi similaires que possible.

---

# 13. Résultats attendus

À la fin du projet, les résultats attendus sont :

1. Une étude comparative des principales approches de recherche vectorielle.

2. Une architecture documentée de KÓTÀA Vector Engine.

3. Un prototype fonctionnel développé en Zig.

4. Un moteur capable d'effectuer des recherches de similarité vectorielle.

5. Une implémentation de la recherche exacte et approximative.

6. Une optimisation des calculs grâce à SIMD.

7. Une implémentation d'un index HNSW.

8. Une réduction de la consommation mémoire grâce à des techniques de quantification.

9. Un système de stockage persistant.

10. Une interface permettant l'utilisation du moteur par une application externe.

11. Une intégration expérimentale dans un système RAG.

12. Un benchmark reproductible permettant de comparer les performances de KÓTÀA avec des solutions existantes.

13. Une analyse des scénarios dans lesquels KÓTÀA présente des avantages ou des limitations.

---

# 14. Limites du projet

Compte tenu de la durée et des ressources disponibles, le projet pourra se limiter à un prototype expérimental.

La conception d'une architecture distribuée à très grande échelle, la réplication, le sharding et la haute disponibilité pourront être considérés comme des perspectives d'évolution et ne constitueront pas nécessairement des objectifs obligatoires de la première version.

L'objectif principal restera la conception et l'évaluation d'un moteur de recherche vectorielle performant sur une architecture mono-machine.

---

# 15. Apport scientifique et technique

Ce projet permettra d'étudier concrètement le compromis entre :

* performance ;
* précision ;
* consommation mémoire ;
* complexité algorithmique ;
* optimisation bas niveau.

Il permettra également d'évaluer l'intérêt du langage Zig pour le développement de logiciels systèmes appliqués à l'intelligence artificielle et aux systèmes de recherche vectorielle.

Le projet pourra également servir de base à des travaux futurs portant sur :

* la recherche vectorielle multilingue ;
* les systèmes RAG spécialisés ;
* la recherche hybride ;
* les systèmes distribués ;
* les architectures de bases de données vectorielles.

---

# 16. Plan prévisionnel du mémoire

## Chapitre 1 : Introduction générale

* Contexte
* Problématique
* Questions de recherche
* Hypothèses
* Objectifs
* Méthodologie

## Chapitre 2 : Revue de littérature

* Intelligence artificielle générative
* LLM
* Embeddings
* RAG
* Recherche vectorielle
* Bases de données vectorielles

## Chapitre 3 : Étude des solutions existantes

* FAISS
* ChromaDB
* Qdrant
* Autres solutions
* Comparaison des architectures

## Chapitre 4 : Conception de KÓTÀA Vector Engine

* Architecture générale
* Structures de données
* Indexation
* SIMD
* HNSW
* Quantification
* Stockage

## Chapitre 5 : Implémentation

* Environnement de développement
* Implémentation en Zig
* Modules du système
* API
* Intégration RAG

## Chapitre 6 : Expérimentation et évaluation

* Protocole expérimental
* Jeux de données
* Matériel utilisé
* Métriques
* Benchmarks
* Comparaison avec les solutions existantes

## Chapitre 7 : Analyse et discussion

* Interprétation des résultats
* Forces
* Limites
* Compromis performance/précision
* Discussion des hypothèses

## Chapitre 8 : Conclusion et perspectives

* Bilan
* Contributions
* Limites
* Perspectives d'amélioration

---

# 17. Mots-clés

**Intelligence artificielle, Retrieval-Augmented Generation, RAG, recherche vectorielle, base de données vectorielle, Zig, SIMD, HNSW, quantification, Approximate Nearest Neighbor, optimisation des performances, recherche hybride.**

---

## 18. Formulation courte pour la fiche de proposition

> **Sujet :** Conception, implémentation et évaluation comparative d'un moteur de recherche vectorielle haute performance en Zig pour les systèmes RAG.
>
> **Résumé :** Ce projet consiste à concevoir et implémenter KÓTÀA Vector Engine, un moteur de recherche vectorielle développé en Zig et destiné aux systèmes de Retrieval-Augmented Generation. Le système intégrera progressivement des techniques d'optimisation telles que SIMD, HNSW, la quantification et la gestion optimisée de la mémoire. Ses performances seront évaluées selon plusieurs critères, notamment la latence, le débit, la précision de recherche, la consommation mémoire et le temps d'indexation. Une comparaison expérimentale avec des solutions existantes telles que FAISS et ChromaDB permettra d'identifier les avantages et les limites de l'approche proposée.
