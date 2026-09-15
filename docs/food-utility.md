# FoodUtility V1 — baseline funcional

Status: **aprovada e estável**. Esta V1 avalia somente valor alimentar
determinístico por `fullType`; não usa o estado de uma instância no mundo
(fresco, cozido, queimado, podre ou tamanho variável).

## Baseline de integração

| Sinal | Valor |
|---|---:|
| Assinatura do registry | `351051:972262668:1327998887` |
| Registry revision | `96` |
| Tipos escaneados | `3416` |
| Ocorrências de loot | `97818` |
| Segundo rescan manual | `MATCH` |

## Elegibilidade

`FOOD` é consumo direto quantificável. `DRINK` exige evidência estrutural de
consumo como bebida (tipo de consumo e som de beber), e não apenas
`ThirstChange` positivo. Alimentos sólidos hidratantes continuam `FOOD`, com
`HYDRATING` como característica secundária.

Ficam `PARTIAL`, sem promoção automática por FoodUtility:

- `CantEat=true` (`CANT_EAT_REQUIRED`);
- `OnCooked` declarado (`PREPARATION_REQUIRED`);
- `RemoveNegativeEffectOnCooked` ou `ReplaceOnCooked` sem prova inequívoca
  (`PREPARATION_AMBIGUOUS`);
- ingredientes e sinais de preparação não quantificados
  (`INGREDIENT_UNQUANTIFIED`);
- callbacks/efeitos especiais, álcool, veneno ou valores por instância não
  quantificáveis (`SPECIAL_UNQUANTIFIED` / `VARIABLE_INSTANCE_VALUE`).

Peixes são excluídos antes da classificação de Food: itens estruturais de
`Fishing.onCreateFish` pertencem exclusivamente a **FishUtility V1**. Seus
valores dependem do tamanho da instância e não representam uma FoodQuality
honesta por `fullType`.

## Fontes estáticas validadas

A auditoria comparou ScriptItem com duas instâncias canônicas temporárias para
os 324 FOOD/DRINK elegíveis e não encontrou valor instável. Cada campo usa a
fonte determinística que a B42 expõe corretamente:

| Atributo | Fonte |
|---|---|
| Hunger / Thirst | ScriptItem |
| Unhappy / Boredom | ScriptItem ou runtime equivalente |
| Stress | ScriptItem |
| DaysFresh / DaysTotallyRotten | ScriptItem |
| Calories | instância runtime canônica temporária |
| MinutesToCook / MinutesToBurn / UseDelta | fonte equivalente disponível |
| Cookable | runtime canônico |
| DangerousUncooked | ScriptItem |

Quando necessário, a instância temporária é restaurada para a forma base
(idade zero, não cozida, não queimada, não podre e não congelada). Escalas da
API são preservadas; conversões explícitas são feitas apenas onde a ponte
runtime usa frações, como Hunger/Thirst/Stress.

## Fórmula congelada

Para `FOOD`:

```text
FoodQuality bruto =
  60% Sustenance
  20% MoodBenefit
  12% Energy
   5% Preservation
   3% Convenience

x = NegativeEffects / 100
NegativeMultiplier = 1 - 0.80 * x^1.5
FoodQuality = FoodQuality bruto * NegativeMultiplier

FinalFoodScore = 95% FoodQuality + 5% FoodScarcityStrength
```

`Hydration` tem peso **0%** para `FOOD`; para `DRINK`, hidratação é o eixo
dominante e sua população é isolada. Peso e macronutrientes individuais não
participam desta V1.

### MoodBenefit

Benefícios usam o sinal real do jogo: redução de Unhappiness, Boredom e Stress
(valores negativos) é positiva. Cada eixo é normalizado e saturado
independentemente no p90, evitando que a escala menor de Stress seja apagada
ou que um valor extremo domine:

```text
MoodBenefit = 50% Unhappiness + 20% Boredom + 30% Stress
```

### Energia, conservação e riscos

- `Energy` usa retorno decrescente: `100 * calories / (calories + 600)`.
- `Preservation` é bônus limitado por vida útil declarada.
- `Convenience` considera requisito de preparo e tempo de cozimento.
- `NegativeEffects` reúne desconforto, tédio, stress positivo, food sickness,
  perigo cru e veneno; `POWER15` quase não afeta risco baixo e cresce
  progressivamente em risco alto.

FoodQuality determina a faixa principal (`COMMON`, `UNCOMMON`, `RARE`,
`EPIC`, `EXOTIC`); Scarcity apenas resolve casos próximos e é condição
complementar de EXOTIC. Scarcity nunca transforma alimento fraco em EPIC ou
EXOTIC.

## Sanity checks

- `Base.Icecream` fica acima de `Base.IcecreamMelted` quando seus benefícios
  de humor declarados são superiores.
- `Base.PizzaWhole` e `Base.PeanutButter` são fortes por sustento, humor e
  energia, não por Scarcity isolada.
- `Base.DogfoodOpen` recebe atenuação forte por efeitos negativos.
- `Base.Toast` permanece baixo mesmo quando sua Scarcity de loot é alta.
- Rice, feijões secos, Watermelon inteira e preparações ficam PARTIAL se
  exigirem preparo ou transformação, em vez de usar stats de alimento final.

## Limitações conhecidas

- Ingredientes e preparações terão uma futura `IngredientUtility`, não uma
  estimativa improvisada nesta V1.
- Efeitos especiais não quantificados permanecem PARTIAL por segurança.
- A população de DRINK pode ser pequena; `FoodUtilityConfidence` mede
  completude de atributos e `FoodRankingConfidence` mede apenas a robustez do
  ranking. Um p100 de DRINK pequeno não promove sozinho um item para EXOTIC.
- A raridade é de `fullType`, portanto o estado de uma unidade no mundo nunca
  muda seu tier visual.
