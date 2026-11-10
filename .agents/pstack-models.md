# pstack model configuration. One line per role. Delete a line to fall back to the skill default.
# `inherit-parent` or `auto` as a value: the role runs on the parent chat model (omit the model). Alias entries in a panel list still count toward its fan-out.
# budget: large (xhigh)
# opencode-go only. Default workhorse is DeepSeek V4.1 Flash; judgment roles take
# Muse Spark 1.3 Contributor as the different class of model. DeepSeek has no xhigh
# variant, so xhigh-budget DeepSeek roles resolve to its highest step at or below
# xhigh, which is `high`.
feature, refactoring: opencode-go/deepseek-v4.1-flash#high
bug-fix: opencode-go/deepseek-v4.1-flash#high
perf-issue: opencode-go/deepseek-v4.1-flash#high
hillclimb: opencode-go/deepseek-v4.1-flash#high
judgment and prose: opencode-go/muse-spark-1.3-contributor#xhigh
hardest tasks: opencode-go/muse-spark-1.3-contributor#xhigh
how explorer: opencode-go/deepseek-v4.1-flash#high
how explainer: opencode-go/muse-spark-1.3-contributor#xhigh
why investigators: opencode-go/deepseek-v4.1-flash#high
why synthesizer: opencode-go/muse-spark-1.3-contributor#xhigh
reflect tooling: opencode-go/deepseek-v4.1-flash#high
reflect judgment, divergent, synthesizer: opencode-go/muse-spark-1.3-contributor#xhigh
arena runners: opencode-go/deepseek-v4.1-flash#high, opencode-go/muse-spark-1.3-contributor#xhigh
arena cross-judge pool: opencode-go/muse-spark-1.3-contributor#xhigh, opencode-go/deepseek-v4.1-flash#high
swarm workers: opencode-go/deepseek-v4.1-flash#high
architect runners: opencode-go/deepseek-v4.1-flash#high, opencode-go/muse-spark-1.3-contributor#xhigh
interrogate reviewers: opencode-go/deepseek-v4.1-flash#high, opencode-go/muse-spark-1.3-contributor#xhigh
