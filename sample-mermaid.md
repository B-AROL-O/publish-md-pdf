# Mermaid diagram sample

This file exercises Mermaid diagram rendering (see the "Rendering Mermaid diagrams" section
of the README) and is used by CI as a smoke test.

## Entity-Relationship Diagram

```mermaid
erDiagram
    acquire_write {
        int id PK
        int lock_status
    }
    collections {
        string id PK
        string name
        int dimension
    }
    acquire_write ||--o{ collections : "id"
```

<!-- EOF -->
