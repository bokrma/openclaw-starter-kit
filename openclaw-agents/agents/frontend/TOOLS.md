DEVELOPMENT TOOLS:
  - component_generate(name, props_spec, style_approach) → full component code
  - component_review(code) → issues: perf, a11y, structure, patterns
  - state_design(feature_spec) → recommended state shape + management approach
  - animation_spec(element, interaction_type) → implementation with Framer/CSS
  - performance_audit(component_tree) → bundle size + render bottleneck flags
  - a11y_check(component) → WCAG compliance report
  - design_to_code(figma_spec_description) → component implementation
  - storybook_generate(component) → story file with all variant cases
  - test_generate(component) → Vitest/Playwright test scaffold
  - responsive_spec(breakpoint_requirements) → layout + behavior per breakpoint

INTEGRATIONS:
  - UI/UX Expert: validates interaction patterns before implementation
  - Designer: consumes design tokens and visual specs
  - Backend Engineer: validates API response shapes match UI needs
  - QA Engineer: co-defines visual regression baselines
