;;; macher-agent-vfs.el --- Virtual File System Abstraction -*- lexical-binding: t; -*-

(require 'cl-lib)

(declare-function macher-agent--run-async-cmd "macher-agent-context-tools" (name cmd dir callback))
(declare-function macher-agent--build-rsync-cmd "macher-agent-context-tools" (source dest))

(cl-defstruct macher-agent-vfs
  "A virtual file system that overlays in-memory edits on a physical project directory."
  root-dir
  overlay)

(defun macher-agent-vfs-create (root-dir)
  "Create a new VFS instance with a given ROOT-DIR."
  (make-macher-agent-vfs :root-dir root-dir :overlay (make-hash-table :test 'equal)))

(defun macher-agent-vfs-add-overlay (vfs path content)
  "Add a virtual file overlay to the VFS."
  (puthash path content (macher-agent-vfs-overlay vfs)))

(defun macher-agent-vfs-get-execution-path (vfs callback)
  "Create a temporary sandbox with the VFS overlay and pass the path to CALLBACK."
  (let* ((project-root (macher-agent-vfs-root-dir vfs))
         (overlay (macher-agent-vfs-overlay vfs))
         (temp-dir (file-name-as-directory (make-temp-file "sandbox-" t)))
         (rsync-cmd (macher-agent--build-rsync-cmd project-root temp-dir))
         (cleanup-fn (lambda () (delete-directory temp-dir t))))
    
    (message "Syncing to sandbox: %s" temp-dir)
    
    (macher-agent--run-async-cmd 
     "rsync" rsync-cmd project-root
     (lambda (exit-code output)
       (if (not (= exit-code 0))
           (progn
             (funcall cleanup-fn)
             (funcall callback nil (format "ERROR: Rsync failed.\nCommand: %s\nOutput: %s" 
                                           rsync-cmd (string-trim output))))
         
         (maphash (lambda (path content)
                    (let ((full-path (expand-file-name path temp-dir)))
                      (if content
                          (progn
                            (make-directory (file-name-directory full-path) t)
                            (with-temp-file full-path (insert content)))
                        (when (file-exists-p full-path)
                          (delete-file full-path)))))
                  overlay)
         
         (funcall callback temp-dir nil))))))

(provide 'macher-agent-vfs)
;;; macher-agent-vfs.el ends here
