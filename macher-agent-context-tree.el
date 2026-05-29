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
  path      ; Full relative path for files
  active)   ; Boolean: Is this file currently in the agent's memory?

;; --- Core Tree Logic ---

(defun macher-agent-context-tree--pp (node)
  "Pretty-printer for the ewoc tree nodes."
  (let ((indent (make-string (* 2 (macher-agent-tree-node-depth node)) ?\s)))
    (pcase (macher-agent-tree-node-type node)
      ('root
       (insert indent (propertize (concat "▾ " (macher-agent-tree-node-name node)) 'face 'font-lock-keyword-face) "\n"))
      ('dir
       (insert indent (propertize (concat "▾ " (macher-agent-tree-node-name node)) 'face 'font-lock-type-face) "\n"))
      ('file
       (let ((display-name (if (macher-agent-tree-node-active node)
                               (propertize (concat (macher-agent-tree-node-name node) " (loaded)") 'face 'bold)
                             (macher-agent-tree-node-name node))))
         (insert indent "  " display-name "\n")))
      ('buffer
       (insert indent "  " (propertize (macher-agent-tree-node-name node) 'face 'bold) "\n")))))

(defun macher-agent-context-tree--flatten-hash (table depth depth-offset current-path active-hash)
  "Recursively flatten the prefix TABLE into ordered ewoc nodes."
  (let ((result nil)
        (keys (sort (hash-table-keys table) #'string<)))
    (dolist (k keys)
      (let* ((val (gethash k table))
             (node-path (if (string-empty-p current-path) k (concat current-path "/" k))))
        (if (eq val 'file)
            (push (make-macher-agent-tree-node :type 'file 
                                               :name k 
                                               :depth (+ depth depth-offset) 
                                               :path node-path
                                               :active (gethash node-path active-hash)) 
                  result)
          (push (make-macher-agent-tree-node :type 'dir 
                                             :name k 
                                             :depth (+ depth depth-offset)) 
                result)
          (setq result (append (nreverse (macher-agent-context-tree--flatten-hash val (1+ depth) depth-offset node-path active-hash)) result)))))
    (nreverse result)))

(defun macher-agent-context-tree--build-file-nodes (files depth-offset active-hash)
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
    
    ;; 2. Flatten the tree recursively, passing down the active context tracker
    (macher-agent-context-tree--flatten-hash tree 0 depth-offset "" active-hash)))

(defun macher-agent-context-tree--render-buffers (ewoc buffers)
  "Render active BUFFERS into the EWOC tree."
  (when buffers
    (ewoc-enter-last ewoc (make-macher-agent-tree-node :type 'root :name "Active Buffers" :depth 0))
    (dolist (b buffers)
      (ewoc-enter-last ewoc (make-macher-agent-tree-node :type 'buffer :name b :depth 1 :path b)))))

(defun macher-agent-context-tree--render-files (ewoc all-files active-files-hash)
  "Render ALL-FILES into the EWOC tree, flagging active files."
  (when all-files
    (ewoc-enter-last ewoc (make-macher-agent-tree-node :type 'root :name "Workspace" :depth 0))
    (dolist (node (macher-agent-context-tree--build-file-nodes all-files 1 active-files-hash))
      (ewoc-enter-last ewoc node))))

(defun macher-agent-context-tree--populate (ewoc context)
  "Extract the complete workspace structure and flag items currently in CONTEXT."
  (let* ((workspace (when (fboundp 'macher-context-workspace)
                      (macher-context-workspace context)))
         (root-dir (when workspace (macher--workspace-root workspace)))
         (project-name (if root-dir
                           (file-name-nondirectory (directory-file-name root-dir))
                         "Agent Workspace"))
         
         ;; Fetch native data
         (workspace-files (when workspace (macher--workspace-files workspace)))
         (contents (macher-context-contents context))
         
         (buffers nil)
         (all-files nil)
         (active-files-hash (make-hash-table :test 'equal)))

    ;; Top Header
    (ewoc-set-hf ewoc (propertize project-name 'face 'bold) "")

    ;; 1. Determine what is currently "active" in the agent's memory
    (dolist (entry contents)
      (let* ((path-or-buf (car entry))
             (classification (macher-agent-context-classify-entry path-or-buf root-dir)))
        
        (if (memq classification '(file media))
            ;; It's a file in the workspace: format it relatively and flag it as active
            (let ((rel-path path-or-buf))
              (when (and root-dir (file-name-absolute-p path-or-buf))
                (setq rel-path (file-relative-name path-or-buf root-dir)))
              (puthash rel-path t active-files-hash))
          ;; It's a buffer or external file, add it directly to the buffer list
          (push path-or-buf buffers))))

    ;; 2. Gather ALL files natively from the project workspace
    (dolist (f workspace-files)
      (let ((rel-path (if (and root-dir (file-name-absolute-p f))
                          (file-relative-name f root-dir)
                        f)))
        (push rel-path all-files)))

    ;; 3. Ensure virtual files (proposed by the agent but not yet on disk) are included
    (maphash (lambda (active-file _val)
               (unless (member active-file all-files)
                 (push active-file all-files)))
             active-files-hash)

    ;; Sort our lists cleanly
    (setq buffers (sort buffers #'string<))
    (setq all-files (sort all-files #'string<))

    (macher-agent-context-tree--render-buffers ewoc buffers)
    (macher-agent-context-tree--render-files ewoc all-files active-files-hash)))

;; --- State & Modes ---

(defvar-local macher-agent-context-tree--ewoc nil
  "The active ewoc instance managing the sidebar.")

(defvar-local macher-agent-context-tree--target-buffer nil
  "The buffer whose context this tree is currently tracking.")

(define-derived-mode macher-agent-context-tree-mode special-mode "MacherTree"
  "Major mode for displaying the macher agent context hierarchy."
  (setq truncate-lines t)
  (setq buffer-read-only t)
  (setq-local cursor-type nil)
  (setq-local cursor-in-non-selected-windows nil))

;; --- Interactive Commands ---

;;;###autoload
(defun macher-agent-context-tree ()
  "Toggle the context tree sidebar for the current buffer.
Displays the full workspace, highlighting items actively in the macher context."
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
          
          (let ((inhibit-read-only t))
            (erase-buffer)
            (setq macher-agent-context-tree--ewoc (ewoc-create #'macher-agent-context-tree--pp "" ""))
            (macher-agent-context-tree--populate macher-agent-context-tree--ewoc context)))

        (display-buffer tree-buf
                        `((display-buffer-in-side-window)
                          (side . left)
                          (window-width . ,macher-agent-context-tree-width)
                          (window-parameters . ((no-other-window . t)))))))))

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
(add-hook 'macher-agent-context-mutated-hook #'macher-agent-context-tree-refresh)

;; Attach to gptel's native hook to ensure a refresh when the LLM turn ends
(add-hook 'gptel-post-response-functions #'macher-agent-context-tree-refresh)

(provide 'macher-agent-context-tree)
;;; macher-agent-context-tree.el ends here
