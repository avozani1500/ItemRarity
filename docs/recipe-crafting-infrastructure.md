# RecipeValue / CraftingValue — infraestrutura futura

Infraestrutura deliberadamente adiada para 1.1. O estado histórico abaixo
permanece registrado no baseline funcional `364797:922118181:1738042128`.

Nenhum score, tier, parser de scripts ou mudança de comportamento foi
implementado a partir desta investigação.

## O que a bridge runtime expõe

- `ScriptManager:getAllCraftRecipes()` enumera as `CraftRecipe` carregadas
  genericamente (vanilla e mods); a auditoria atual observou 1.047 receitas.
- Cada receita enumera coleções de `Inputs`, `Outputs` e `RequiredSkills`.
- Nome da receita e tempo também são expostos.

## O que ainda não é seguro usar

Os objetos internos `InputScript` e `OutputScript` mostram membros para itens,
quantidade e flags, mas as assinaturas públicas não foram confirmadas de forma
segura. Chamar um overload com aridade errada produz erro no log do motor,
mesmo quando protegido por `pcall`.

Também não há acesso confiável, na bridge atual, para ferramentas requeridas,
estações/workbenches, callbacks, condições especiais, alternativas completas
ou o grafo de receitas encadeadas.

## Decisão

Uma futura camada adaptadora deve validar as assinaturas de `InputScript` e
`OutputScript` pela bridge runtime antes de qualquer cálculo. Enquanto isso,
Materials, Tools e itens produzidos continuam em fallback/Scarcity. Não usar
parser paralelo de scripts: isso reduziria a generalidade para mods e criaria
dependência de carregamento/implementação duplicada.

Em termos de gameplay: ferramentas e materiais cuja utilidade principal vem de
crafting, construção, farming ou ações de mundo podem ser subestimados até que
as relações `CraftRecipe ↔ Input/Tool` sejam expostas de forma confiável.

## Decisão adicional: ToolUtility V1

Antes do lançamento 1.0, foi feita uma auditoria separada de `ToolUtility V1`
sem usar grafo de receitas. Tags estruturais conseguem identificar algumas
ferramentas reutilizáveis — por exemplo domínios de construção, corte,
fixação e trabalho de solo — e `ConditionMax`, `UseDelta`, replacement e peso
estão disponíveis.

Isso não é suficiente para um score seguro. A bridge não informa quantas
oportunidades reais cada ferramenta habilita, se alternativas a substituem, ou
o valor comparável das ações de mundo. Para itens que também são armas, somar
esse sinal a WeaponUtility cria risco de double-counting e promoções artificiais.

Decisão: `TOOL_V1_NOT_SAFE`. A detecção permanece útil apenas como diagnóstico;
nenhuma ToolUtility entra no 1.0. A reavaliação pertence ao 1.1, junto com uma
bridge confiável de relações `CraftRecipe ↔ Input/Tool` e ações de mundo.
