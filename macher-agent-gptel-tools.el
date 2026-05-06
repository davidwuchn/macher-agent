;;; macher-agent-gptel-tools.el --- Pure gptel orchestration tools -*- lexical-binding: t; -*-

(defvar macher-agent-spawn-subagent-tool
  (gptel-make-tool
   :name "spawn_subagent"
   :description "Create a new, isolated sub-agent in the current project directory. You provide the name. Use this to spin up a worker for a specific task."
   :category "macher-agent-plan"
   :args (list '(:name "name" :type string :description "The name of the new sub-agent."))
   :function (lambda (name)
               (let ((buf-name (format "*macher-agent: %s*" name)))
                 (macher-agent-add-subagent name default-directory t)
                 (format "SUCCESS: Sub-agent created. The EXACT buffer name to use for tools is '%s'." buf-name)))))

(defvar macher-agent-write-to-buffer-tool
  (gptel-make-tool
   :name "write_to_buffer"
   :description "Write complete content to a specific Emacs buffer. You must call this tool ONLY ONCE per task."
   :category "macher-agent-plan"
   :args (list '(:name "buffer_name" :type string :description "The exact name of the destination buffer.")
               '(:name "content" :type string :description "The text content to write."))
   :function (lambda (buffer_name content)
               (let* ((actual-name (macher-agent--resolve-buffer-name buffer_name))
                      (target-buffer (get-buffer-create actual-name)))
                 (with-current-buffer target-buffer
                   (goto-char (point-max))
                   (insert "\n\n" (substring-no-properties content) "\n"))
                 (format "SUCCESS: Content successfully dispatched to buffer '%s'." actual-name)))))

(defvar macher-agent-execute-nonblocking-tool
  (gptel-make-tool
   :name "execute_subagent_buffer_nonblocking"
   :description "Trigger a sub-agent to begin processing asynchronously without waiting for it to finish."
   :category "macher-agent-plan"
   :args (list '(:name "buffer_name" :type string :description "The exact name of the destination buffer."))
   :function (lambda (buffer_name)
               (let* ((actual-name (macher-agent--resolve-buffer-name buffer_name))
                      (buf (get-buffer actual-name)))
                 (if (not (buffer-live-p buf))
                     (format "ERROR: Buffer '%s' does not exist." actual-name)
                   (with-current-buffer buf
                     (if (get-text-property (max (point-min) (1- (point-max))) 'gptel)
                         "ERROR: Cannot execute. You must use 'write_to_buffer' to give new instructions first."
                       (goto-char (point-max))
                       (condition-case err
                           (progn
                             (gptel-send)
                             (format "SUCCESS: Sub-agent in '%s' triggered asynchronously." actual-name))
                         (file-error
                          (format "ERROR: File permission denied (%s). Do not spawn agents in protected OS folders." (caddr err)))
                         (error
                          (format "ERROR during execution: %S" err))))))))))

(defvar macher-agent-execute-blocking-tool
  (gptel-make-tool
   :name "execute_subagent_buffer_blocking"
   :description "Trigger a sub-agent and WAIT for it to finish its task before continuing. Call this after dispatching instructions via write_to_buffer."
   :category "macher-agent-plan"
   :async t
   :args (list '(:name "buffer_name" :type string :description "The exact name of the destination buffer."))
   :function (lambda (callback buffer_name)
               (let* ((actual-name (macher-agent--resolve-buffer-name buffer_name))
                      (buf (get-buffer actual-name)))
                 (if (not (buffer-live-p buf))
                     (funcall callback (format "ERROR: Buffer '%s' does not exist." actual-name))
                   (with-current-buffer buf
                     (if (get-text-property (max (point-min) (1- (point-max))) 'gptel)
                         (funcall callback "ERROR: Cannot execute. You must use 'write_to_buffer' to give new instructions first.")
                       (setq-local macher--fsm-latest nil)
                       (setq-local macher-agent--gptel-finished nil)
                       (add-hook 'gptel-post-response-functions #'macher-agent--gptel-finished-hook nil t)
                       (goto-char (point-max))
                       (condition-case err
                           (progn
                             (gptel-send)
                             (macher-agent--catch-fsm-and-wait buf callback actual-name 0))
                         (file-error
                          (funcall callback (format "ERROR: File permission denied (%s). Do not spawn agents in protected OS folders." (caddr err))))
                         (error
                          (funcall callback (format "ERROR starting request: %S" err)))))))))))


(with-eval-after-load 'macher
  (gptel-make-preset "macher-agent-plan"
    :description "Project planning, architectural analysis, and sub-agent orchestration"
    :tools '("read_file_in_workspace" 
             "list_directory_in_workspace" 
             "search_in_workspace"
             "get_current_time"
             "spawn_subagent"
             "write_to_buffer"
             "execute_subagent_buffer_blocking")))

(provide 'macher-agent-gptel-tools)
;;; macher-agent-gptel-tools.el ends here
