# FirearmUtility V1 — baseline funcional

Status: **aprovada e estável**. Não recalibrar componentes, referência ou
política de tier sem uma tarefa específica de revisão de FirearmUtility.

## Baseline de integração

| Sinal | Valor |
|---|---:|
| Assinatura do registry | `364598:2089445955:1182970673` |
| Registry revision | `151` |
| Tipos escaneados | `3416` |
| Ocorrências de loot | `97818` |
| Rescan manual determinístico | `MATCH` |

## Referência e comparação

- A escala absoluta é ancorada nos **21 perfis mecânicos vanilla** de firearms.
- A normalização usa winsorização **p05–p95** por eixo.
- Mods futuros são avaliados contra esses anchors vanilla; não redefinem a
  população de referência.
- A comparação relativa continua local à família (`AUTOMATIC_RIFLE`, `RIFLE`,
  `SHOTGUN`, `HANDGUN` ou `LONG_GUN`). `RankingConfidence` controla apenas o
  peso desse refinamento e nunca neutraliza o valor absoluto.

## Modelo B congelado

`CombinedFirearmScore` é formado por:

- Offense: **50%** — dano médio 70%, multi-hit saturado 20%, crítico 10%;
- Capacity / sustain: **20%**;
- Handling: **20%** — recoil 30%, mira 25%, recarga 25%, peso 15%, som 5%;
- Range: **10%**.

O score final adiciona somente o refinamento aprovado de escassez:

`FinalFirearmScore = 95% CombinedFirearmScore + 5% ScarcityStrength`

Os tiers funcionais são diretos: `<40 COMMON`, `40–54.99 UNCOMMON`,
`55–69.99 RARE`, `70–84.99 EPIC`, `>=85 EXOTIC`.

## Correção estrutural importante

As cap guns vanilla são firearms estruturais — são ranged e possuem mecanismo
de munição — embora o classificador amplo não as rotule como `WEAPON`/`TOOL`.
Elas estavam presentes no audit, mas ausentes do runtime ativo, reduzindo a
referência de 21 para 19 perfis e comprimindo os bounds p05–p95.

A V1 detecta firearms antes do filtro genérico de categoria. Isso inclui as
duas cap guns exclusivamente no mesmo universo estrutural da simulação,
restaurando os 21 perfis e os bounds validados. Não há hardcode por fullType.

## Sanity checks congelados

| Item | Tier |
|---|---|
| M16 / `Base.AssaultRifle` | EXOTIC |
| M14 / `Base.AssaultRifle2` | EXOTIC |
| JS3T Shotgun | EXOTIC |
| Shotgun | EPIC |
| L92 Carbine | RARE |
| Pistol3 | RARE |

Distribuição vanilla validada: **3 COMMON / 5 UNCOMMON / 7 RARE / 4 EPIC /
3 EXOTIC**.
