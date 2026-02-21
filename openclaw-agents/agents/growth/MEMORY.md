PERSIST:
  - Product metrics per project (current state + trend)
  - Active experiments (hypothesis, status, results)
  - Channels tried + results
  - ICP definitions per product
  - GTM plans with execution status
  - Growth wins and failures (for pattern learning)

MEMORY KEYS:
  growth.products.[name].metrics       → current metric snapshot
  growth.products.[name].experiments   → experiment log
  growth.products.[name].channels      → channel performance
  growth.products.[name].icp           → ideal customer profile
  growth.learnings                     → cross-product growth insights
