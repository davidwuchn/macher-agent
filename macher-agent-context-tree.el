;;; macher-agent-context-tree.el --- Context tree sidebar -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ewoc)
(require 'macher-agent-context)
(eval-when-compile (require 'subr-x))

;; --- Configuration ---

(defcustom macher-agent-context-tree-width 30
  "Default width of the macher agent context tree sidebar window."
  :type 'integer
  :group 'macher-agent)

;; --- Data Structures ---

(cl-defstruct macher-agent-tree-node
  "Represents a single entry in the context ewoc tree."
  type      ; 'header, 'root, 'dir, 'file, or 'buffer
  name      ; Display string for the node
  depth     ; Indentation level for rendering
  path)     ; Full path or buffer name identifier

;; --- Core Tree Logic ---

(defun macher-agent-context-tree--pp (node)
  "Pretty-printer for the ewoc tree nodes."
  (let ((indent (make-string (* 2 (macher-agent-tree-node-depth node)) ?\s)))
    (pcase (macher-agent-tree-node-type node)
      ('header
       (insert (propertize (macher-agent-tree-node-name node) 'face 'bold) "\n\n"))
      ('root
       (insert indent (propertize (concat "▾ " (macher-agent-tree-node-name node)) 'face 'font-lock-keyword-face) "\n"))
      ('dir
       (insert indent (propertize (concat "▾ " (macher-agent-tree-node-name node)) 'face 'font-lock-type-face) "\n"))
      ('file
       (insert indent "  " (macher-agent-tree-node-name node) "\n"))
      ('buffer
       (insert indent "  " (macher-agent-tree-node-name node) "\n")))))

(defun macher-agent-context-tree--flatten-hash (table depth depth-offset)
  "Recursively flatten the prefix TABLE into ordered ewoc nodes."
  (let ((result nil)
        (keys (sort (hash-table-keys table) #'string<)))
    (dolist (k keys)
      (let ((val (gethash k table)))
        (if (eq val 'file)
            (push (make-macher-agent-tree-node :type 'file :name k :depth (+ depth depth-offset)) result)
          (push (make-macher-agent-tree-node :type 'dir :name k :depth (+ depth depth-offset)) result)
          (setq result (append (nreverse (macher-agent-context-tree--flatten-hash val (1+ depth) depth-offset)) result)))))
    (nreverse result)))

(defun macher-agent-context-tree--build-file-nodes (files depth-offset)
  "Convert a list of file paths into a flattened list of hierarchical ewoc nodes."
  (let ((tree (make-hash-table :test 'equal)))
    ;; 1. Build the prefix tree
    (dolist (f files)
      (let* ((parts (split-string f "/" t))
             (current tree))
        (cl-loop for part in parts
                 for i from 1
                 for is-last = (= i (length parts))
                 do (let ((node (gethash part current)))
                      (unless node
                        (setq node (if is-last 'file (make-hash-table :test 'equal)))
                        (puthash part node current))
                      (setq current node)))))
    
    ;; 2. Flatten the tree recursively
    (macher-agent-context-tree--flatten-hash tree 0 depth-offset)))

(defun macher-agent-context-tree--populate (ewoc context)
  "Extract paths directly from CONTEXT and populate the EWOC tree."
  (let* ((contents (macher-context-contents context))
         (workspace (when (fboundp 'macher-context-workspace)
                      (macher-context-workspace context)))
         (root-dir (when workspace (macher--workspace-root workspace)))
         (project-name (if root-dir
                           (file-name-nondirectory (directory-file-name root-dir))
                         "Agent Context"))
         (buffers nil)
         (files nil))

    ;; Top Header
    (ewoc-enter-last ewoc (make-macher-agent-tree-node 
                           :type 'header 
                           :name project-name 
                           :depth 0))

    ;; Categorise entries purely based on their key in the context
    (dolist (entry contents)
      (let* ((path-or-buf (car entry))
             (is-absolute (file-name-absolute-p path-or-buf))
             (has-slash (string-match-p "/" path-or-buf))
             (live-buf (get-buffer path-or-buf))
             (is-file-buffer (and live-buf (buffer-file-name live-buf))))
        
        (if (or is-absolute has-slash is-file-buffer (and root-dir (file-exists-p (expand-file-name path-or-buf root-dir))))
            ;; It's a file: format it relatively if possible
            (let ((rel-path path-or-buf))
              (when (and root-dir is-absolute)
                (setq rel-path (file-relative-name path-or-buf root-dir)))
              (push rel-path files))
          ;; It's a pure buffer
          (push path-or-buf buffers))))

    (setq buffers (sort buffers #'string<))
    (setq files (sort files #'string<))

    ;; Buffers Parent
    (when buffers
      (ewoc-enter-last ewoc (make-macher-agent-tree-node :type 'root :name "Buffers" :depth 0))
      (dolist (b buffers)
        (ewoc-enter-last ewoc (make-macher-agent-tree-node :type 'buffer :name b :depth 1 :path b))))

    ;; Files Parent
    (when files
      (ewoc-enter-last ewoc (make-macher-agent-tree-node :type 'root :name "Files" :depth 0))
      (dolist (node (macher-agent-context-tree--build-file-nodes files 1))
        (ewoc-enter-last ewoc node)))))

;; --- State & Modes ---

(defvar-local macher-agent-context-tree--ewoc nil
  "The active ewoc instance managing the sidebar.")

(defvar-local macher-agent-context-tree--target-buffer nil
  "The buffer whose context this tree is currently tracking.")

(define-derived-mode macher-agent-context-tree-mode special-mode "MacherTree"
  "Major mode for displaying the macher agent context hierarchy."
  (setq truncate-lines t)
  (setq buffer-read-only t))

;; --- Interactive Commands ---

;;;###autoload
(defun macher-agent-context-tree ()
  "Toggle the context tree sidebar for the current buffer.
Displays exactly what is inside the active macher context."
  (interactive)
  (let* ((target-buf (current-buffer))
         (context (buffer-local-value 'macher-agent--persistent-context target-buf))
         (tree-buf-name (format "*macher-tree: %s*" (buffer-name target-buf)))
         (tree-window (get-buffer-window tree-buf-name)))

    (unless context
      (user-error "No active macher context in the current buffer."))

    (if tree-window
        (delete-window tree-window)
      (let ((tree-buf (get-buffer-create tree-buf-name)))
        
        (with-current-buffer tree-buf
          (macher-agent-context-tree-mode)
          (setq macher-agent-context-tree--target-buffer target-buf)
          
          ;; Initialise and populate the tree (Using "" to prevent ewoc's default carriage return)
          (let ((inhibit-read-only t))
            (erase-buffer)
            (setq macher-agent-context-tree--ewoc (ewoc-create #'macher-agent-context-tree--pp "" ""))
            (macher-agent-context-tree--populate macher-agent-context-tree--ewoc context)))

        (display-buffer tree-buf
                        `((display-buffer-in-side-window)
                          (side . left)
                          (window-width . ,macher-agent-context-tree-width)))))))

;; --- Synchronisation Hook ---

(defun macher-agent-context-tree-refresh (&rest _args)
  "Refresh all visible context trees when the underlying context state mutates."
  (dolist (win (window-list))
    (let ((buf (window-buffer win)))
      (with-current-buffer buf
        (when (derived-mode-p 'macher-agent-context-tree-mode)
          (let* ((target macher-agent-context-tree--target-buffer)
                 (context (when (buffer-live-p target)
                            (buffer-local-value 'macher-agent--persistent-context target))))
            (when context
              (let ((inhibit-read-only t))
                (erase-buffer)
                (setq macher-agent-context-tree--ewoc (ewoc-create #'macher-agent-context-tree--pp "" ""))
                (macher-agent-context-tree--populate macher-agent-context-tree--ewoc context)))))))))

;; Advise the core context modification functions to automatically refresh the sidebar
(advice-add 'macher-agent--update-context-file :after #'macher-agent-context-tree-refresh)
(advice-add 'macher-agent--add-buffer-to-scope-headless :after #'macher-agent-context-tree-refresh)
(advice-add 'macher-agent--auto-sync-context :after #'macher-agent-context-tree-refresh)
(advice-add 'macher-agent-clear-context :after #'macher-agent-context-tree-refresh)

;; Attach to gptel's native hook to ensure a refresh when the LLM turn ends
(add-hook 'gptel-post-response-functions #'macher-agent-context-tree-refresh)

(provide 'macher-agent-context-tree)
;;; macher-agent-context-tree.el ends here
