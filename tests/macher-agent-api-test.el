;;; macher-agent-api-test.el --- Tests for public API -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'macher-agent-api)

(ert-deftest macher-agent-api-contract-test ()
  "Ensure all public API bridge functions are defined."
  (should (fboundp 'macher-agent-workspace-resolve-path))
  (should (fboundp 'macher-agent-context-read))
  (should (fboundp 'macher-agent-context-update))
  (should (fboundp 'macher-agent-scope-add-file))
  (should (fboundp 'macher-agent-execute-parallel))
  (should (fboundp 'macher-agent-prepare-instructions))
  (should (fboundp 'macher-agent-submit-task-result))
  (should (fboundp 'macher-agent-workspace-root))
  (should (fboundp 'macher-agent-api-register-skills-in-directory))
  (should (fboundp 'macher-agent-ui-show)))


(provide 'macher-agent-api-test)
