# FishUtility V1 — baseline funcional

Status: **aprovada e estável**. Não revisar a fórmula nem os thresholds sem
uma tarefa específica de calibração de FishUtility.

## Baseline de integração

| Signal | Value |
|---|---:|
| Registry/result signature | `351045:1279926696:69761935` |
| Registry revision | `92` |
| Item types scanned | `3416` |
| Loot occurrences | `97818` |
| Deterministic manual rescan | `MATCH` |

FishUtility é independente de Strategy D para o tier funcional: não usa a
escassez das loot distributions. `FishingScarcity` continua publicado como
conceito separado e, nesta V1, corresponde ao `CatchDifficulty` diagnóstico.

## Modelo V1 congelado

- Identificação estrutural: configuração de pesca com tamanho variável,
  equivalente aos itens com `OnCreate = Fishing.onCreateFish`.
- `ExpectedFoodYield` = 80% `ExpectedHunger` + 20% `CaloriesSaturated`.
- `CaloriesSaturated` = `100 * kcal / (kcal + 2000)`.
- `CatchDifficulty` = 60% skill mínima + 20% requisito predator/reel + 20%
  perfil de iscas.
- `PositionScore` = 80% `ExpectedFoodYield` + 20% `CatchDifficulty`.
- Modelo C: o teto vem de `ExpectedFoodYield`; dificuldade apenas posiciona
  a espécie dentro desse teto.
- Strategy D, clima, horário, temperatura, abundância, ruído, chum e
  depletion não participam desta V1.

## População estrutural versus registry publicado

A API `Fishing.fishes` da B42.20.2 contém **20 espécies estruturais**.
O scanner publica apenas itens presentes nas loot distributions carregadas;
no baseline há **18** peixes publicados.

`Base.AligatorGar` e `Base.Paddlefish` possuem FishUtility plenamente
calculável e participam da população de referência de 20 espécies. Porém, não
entram no registry porque não aparecem nas loot distributions carregadas.

Isso é intencional nesta etapa: **não alterar o scanner global para inserir
itens fora do universo de loot**. Portanto, a distribuição publicada dos 18
itens não inclui esses dois, mas a normalização continua usando as 20 espécies
reais da Fishing API.

## Sanity checks congelados

| Species | Expected tier |
|---|---|
| Alligator Gar | EXOTIC (referência estrutural; sem rota de loot) |
| Blue Catfish | EPIC |
| Flathead Catfish | EPIC |
| Paddlefish | EPIC (referência estrutural; sem rota de loot) |
| Muskellunge | RARE |
| Striped Bass | RARE |
| Walleye | RARE |
| Largemouth Bass | UNCOMMON |
| Freshwater Drum | UNCOMMON |
| Bluegill / crappies / sunfish / Yellow Perch | COMMON |

No baseline, os 20 peixes se distribuem em `11/2/3/3/1`
(Common/Uncommon/Rare/Epic/Exotic). Os 18 publicados se distribuem em
`11/2/3/2/0` pela ausência de Alligator Gar e Paddlefish.
