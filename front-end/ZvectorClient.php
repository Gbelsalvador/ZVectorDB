<?php

class ZvectorClient
{
    private string $baseUrl;

    public function __construct(string $host = '127.0.0.1', int $port = 8080)
    {
        $this->baseUrl = "http://{$host}:{$port}/api/v1";
    }

    private function request(string $method, string $endpoint, ?array $payload = null): array
    {
        $ch = curl_init($this->baseUrl . $endpoint);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_CUSTOMREQUEST, strtoupper($method));
        curl_setopt($ch, CURLOPT_TIMEOUT, 5);

        $headers = ['Accept: application/json'];
        if ($payload !== null) {
            $json = json_encode($payload, JSON_UNESCAPED_UNICODE);
            curl_setopt($ch, CURLOPT_POSTFIELDS, $json);
            $headers[] = 'Content-Type: application/json';
            $headers[] = 'Content-Length: ' . strlen($json);
        }

        curl_setopt($ch, CURLOPT_HTTPHEADER, $headers);
        $response = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $error = curl_error($ch);
        curl_close($ch);

        if ($response === false) {
            return ['ok' => false, 'status' => 0, 'error' => "Serveur Zig inaccessible : $error"];
        }

        $decoded = json_decode($response, true);
        return [
            'ok'     => ($httpCode >= 200 && $httpCode < 300),
            'status' => $httpCode,
            'data'   => $decoded ?? $response
        ];
    }

    // --- Collections ---
    public function listCollections(): array
    {
        return $this->request('GET', '/collections');
    }

    public function createCollection(string $name): array
    {
        return $this->request('POST', '/collections', ['name' => $name]);
    }

    public function deleteCollection(string $name): array
    {
        return $this->request('DELETE', '/collections/' . rawurlencode($name));
    }

    // --- Documents ---
    public function listDocuments(string $collection): array
    {
        return $this->request('GET', '/collections/' . rawurlencode($collection) . '/documents');
    }

    public function addDocument(string $collection, string $content): array
    {
        return $this->request('POST', '/collections/' . rawurlencode($collection) . '/documents', [
            'content' => $content
        ]);
    }

    public function updateDocument(string $collection, int $id, string $content): array
    {
        return $this->request('PUT', '/collections/' . rawurlencode($collection) . "/documents/{$id}", [
            'content' => $content
        ]);
    }

    public function deleteDocument(string $collection, int $id): array
    {
        return $this->request('DELETE', '/collections/' . rawurlencode($collection) . "/documents/{$id}");
    }

    // --- Recherche BM25 ---
    public function search(string $collection, string $query): array
    {
        return $this->request('POST', '/collections/' . rawurlencode($collection) . '/search', [
            'query' => $query
        ]);
    }
}