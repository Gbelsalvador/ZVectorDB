<?php
require_once __DIR__ . '/ZvectorClient.php';

$client = new ZvectorClient('127.0.0.1', 8080);
$currentCollection = $_GET['collection'] ?? 'default';
$message = null;
$searchResults = null;
$searchQuery = '';

// Traitement des actions POST
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action = $_POST['action'] ?? '';

    if ($action === 'create_collection' && !empty(trim($_POST['name']))) {
        $name = trim($_POST['name']);
        $res = $client->createCollection($name);
        $message = $res['ok'] ? "Collection « $name » créée." : "Erreur : " . json_encode($res['data']);
        if ($res['ok']) $currentCollection = $name;
    }

    if ($action === 'delete_collection' && !empty($_POST['name'])) {
        $name = $_POST['name'];
        $res = $client->deleteCollection($name);
        $message = $res['ok'] ? "Collection « $name » supprimée." : "Erreur : " . json_encode($res['data']);
        $currentCollection = 'default';
    }

    if ($action === 'add_document' && !empty(trim($_POST['content']))) {
        $res = $client->addDocument($currentCollection, trim($_POST['content']));
        $message = $res['ok'] ? "Document ajouté et indexé." : "Erreur : " . json_encode($res['data']);
    }

    if ($action === 'delete_document' && isset($_POST['doc_id'])) {
        $res = $client->deleteDocument($currentCollection, (int)$_POST['doc_id']);
        $message = $res['ok'] ? "Document supprimé." : "Erreur : " . json_encode($res['data']);
    }

    if ($action === 'search' && !empty(trim($_POST['query']))) {
        $searchQuery = trim($_POST['query']);
        $searchResults = $client->search($currentCollection, $searchQuery);
    }
}

// Récupération des données pour l'affichage
$collectionsRes = $client->listCollections();
$docsRes = $client->listDocuments($currentCollection);
?>
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <title>ZvectorDB — Dashboard PHP</title>
    <style>
        body { font-family: system-ui, sans-serif; background: #0f172a; color: #e2e8f0; margin: 0; padding: 20px; }
        .container { max-width: 1100px; margin: auto; display: grid; grid-template-columns: 280px 1fr; gap: 20px; }
        .card { background: #1e293b; border: 1px solid #334155; border-radius: 8px; padding: 16px; margin-bottom: 16px; }
        h1, h2, h3 { margin-top: 0; color: #38bdf8; }
        input[type="text"], textarea { width: 100%; box-sizing: border-box; padding: 8px; border-radius: 6px; border: 1px solid #475569; background: #0f172a; color: #f8fafc; margin-bottom: 8px; }
        button { background: #0284c7; color: white; border: none; padding: 8px 14px; border-radius: 6px; cursor: pointer; font-weight: 600; }
        button:hover { background: #0369a1; }
        button.danger { background: #dc2626; padding: 4px 8px; font-size: 12px; }
        .col-item { display: flex; justify-content: space-between; align-items: center; padding: 8px; border-radius: 6px; margin-bottom: 4px; background: #0f172a; }
        .col-item.active { border: 1px solid #38bdf8; }
        .col-item a { color: #e2e8f0; text-decoration: none; font-weight: 500; }
        .doc-row { border-bottom: 1px solid #334155; padding: 10px 0; display: flex; justify-content: space-between; gap: 12px; }
        .badge { background: #334155; color: #38bdf8; padding: 2px 8px; border-radius: 999px; font-size: 12px; }
        .alert { background: #065f46; color: #ecfdf5; padding: 10px; border-radius: 6px; margin-bottom: 16px; }
        .error { background: #7f1d1d; color: #fef2f2; padding: 10px; border-radius: 6px; margin-bottom: 16px; }
        pre { background: #020617; padding: 10px; border-radius: 6px; overflow-x: auto; font-size: 13px; }
    </style>
</head>
<body>

<div style="max-width:1100px; margin: 0 auto 16px auto; display:flex; justify-content:space-between; align-items:center;">
    <h1>ZvectorDB Studio <span class="badge">API v1</span></h1>
    <span>Serveur cible : <code>127.0.0.1:8080</code></span>
</div>

<?php if (!$collectionsRes['ok']): ?>
    <div class="error" style="max-width:1100px; margin: 0 auto 16px auto;">
        <?= htmlspecialchars($collectionsRes['error'] ?? 'Impossible de joindre ZvectorDB. Lancez : zig build run -- serve 8080') ?>
    </div>
<?php endif; ?>

<?php if ($message): ?>
    <div class="alert" style="max-width:1100px; margin: 0 auto 16px auto;"><?= htmlspecialchars($message) ?></div>
<?php endif; ?>

<div class="container">
    <!-- Colonne gauche : Collections -->
    <div>
        <div class="card">
            <h3>Collections</h3>
            <?php
            $cols = $collectionsRes['data']['collections'] ?? $collectionsRes['data'] ?? ['default'];
            if (is_array($cols)):
                foreach ($cols as $col):
                    $colName = is_array($col) ? ($col['name'] ?? 'default') : (string)$col;
            ?>
                <div class="col-item <?= $colName === $currentCollection ? 'active' : '' ?>">
                    <a href="?collection=<?= urlencode($colName) ?>"><?= htmlspecialchars($colName) ?></a>
                    <?php if ($colName !== 'default'): ?>
                        <form method="POST" style="margin:0;">
                            <input type="hidden" name="action" value="delete_collection">
                            <input type="hidden" name="name" value="<?= htmlspecialchars($colName) ?>">
                            <button type="submit" class="danger">✕</button>
                        </form>
                    <?php endif; ?>
                </div>
            <?php endforeach; endif; ?>

            <hr style="border-color:#334155; margin: 14px 0;">
            <form method="POST">
                <input type="hidden" name="action" value="create_collection">
                <input type="text" name="name" placeholder="Nouvelle collection..." required>
                <button type="submit" style="width:100%;">+ Créer</button>
            </form>
        </div>
    </div>

    <!-- Colonne droite : Recherche & Documents -->
    <div>
        <!-- Recherche BM25 -->
        <div class="card">
            <h3>Recherche BM25 dans « <?= htmlspecialchars($currentCollection) ?> »</h3>
            <form method="POST" style="display:flex; gap:8px;">
                <input type="hidden" name="action" value="search">
                <input type="text" name="query" value="<?= htmlspecialchars($searchQuery) ?>" placeholder="Ex: langage programmation système..." style="margin:0;" required>
                <button type="submit">Rechercher</button>
            </form>

            <?php if ($searchResults !== null): ?>
                <div style="margin-top:12px;">
                    <strong>Résultats :</strong>
                    <pre><?= htmlspecialchars(json_encode($searchResults['data'], JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE)) ?></pre>
                </div>
            <?php endif; ?>
        </div>

        <!-- Ajout de document -->
        <div class="card">
            <h3>Ajouter un document</h3>
            <form method="POST">
                <input type="hidden" name="action" value="add_document">
                <textarea name="content" rows="2" placeholder="Contenu textuel à indexer..." required></textarea>
                <button type="submit">Indexer le document</button>
            </form>
        </div>

        <!-- Liste des documents -->
        <div class="card">
            <h3>Documents indexés</h3>
            <?php
            $docs = $docsRes['data']['documents'] ?? $docsRes['data'] ?? [];
            if (empty($docs) || !is_array($docs)):
            ?>
                <p style="color:#94a3b8;">Aucun document dans cette collection.</p>
            <?php else: ?>
                <?php foreach ($docs as $idx => $doc):
                    $docId = is_array($doc) ? ($doc['id'] ?? $idx) : $idx;
                    $docContent = is_array($doc) ? ($doc['content'] ?? json_encode($doc)) : (string)$doc;
                ?>
                    <div class="doc-row">
                        <div>
                            <span class="badge">#<?= htmlspecialchars((string)$docId) ?></span>
                            <span style="margin-left:8px;"><?= htmlspecialchars($docContent) ?></span>
                        </div>
                        <form method="POST" style="margin:0;">
                            <input type="hidden" name="action" value="delete_document">
                            <input type="hidden" name="doc_id" value="<?= htmlspecialchars((string)$docId) ?>">
                            <button type="submit" class="danger">Supprimer</button>
                        </form>
                    </div>
                <?php endforeach; ?>
            <?php endif; ?>
        </div>
    </div>
</div>

</body>
</html>