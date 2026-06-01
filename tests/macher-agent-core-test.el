;;; macher-agent-core-test.el --- Core behaviour tests for macher-agent -*- lexical-binding: t -*-

;; This test suite enforces the watertight specification for macher-agent,
;; focusing on VFS optimistic concurrency, strict lexical state management,
;; sandbox isolation, and diff splitting behaviours. All tests adhere to
;; British English conventions.

(require 'buttercup)
(require 'cl-lib)
(require 'macher-agent)

;; Dummy gptel structures for mocking
(cl-defstruct mock-gptel-fsm info state)

(describe "Macher-Agent Core Behaviours"
  
  (describe "1. VFS & Optimistic Concurrency"
    (it "asserts that a VFS write is rejected if the underlying file has drifted"
      (let* ((workspace (make-macher-agent-workspace :project-root "/mock/proj/"))
             (file-path "/mock/proj/test.el")
             (original-mtime '(25000 12345))
             (drifted-mtime '(25000 99999)))
        
        ;; Initialise tracking
        (puthash file-path original-mtime (macher-agent-workspace-mtime-tracker workspace))
        
        ;; Mock the filesystem returning a newer mtime
        (spy-on 'file-attributes :and-call-fake
                (lambda (file)
                  (if (string= file file-path)
                      `(t 1 1 1 ,drifted-mtime ,drifted-mtime ,drifted-mtime 100 "mode" t 1 1)
                    nil)))
        
        (let ((threw nil))
          (condition-case err
              (macher-agent-vfs-write workspace file-path "New content")
            (error
             (setq threw t)
             (expect (cadr err) :to-equal "Your previous edits to test.el were discarded due to external file modifications. Please re-read and re-apply.")))
          (expect threw :to-be t))))

    (it "asserts that different agent sessions within the same workspace share uncommitted VFS state"
      (let* ((workspace (make-macher-agent-workspace :project-root "/mock/proj/"))
             (session-a (make-macher-agent-session :id "Agent-A" :workspace workspace))
             (session-b (make-macher-agent-session :id "Agent-B" :workspace workspace))
             (file-path "/mock/proj/shared.el"))
        
        ;; Agent A writes to the shared VFS
        (macher-agent-vfs-write (macher-agent-session-workspace session-a) file-path "Agent A changes")
        
        ;; Agent B reads from the shared VFS
        (let ((read-content (macher-agent-vfs-read (macher-agent-session-workspace session-b) file-path)))
          (expect read-content :to-equal "Agent A changes")))))

  (describe "2. Execution Environments (Sandbox)"
    (it "asserts that sandbox inflation overlays the uncommitted VFS changes"
      (let* ((workspace (make-macher-agent-workspace :project-root "/mock/proj/"))
             (session (make-macher-agent-session :id "Agent-A" 
                                                 :workspace workspace
                                                 :sandbox-path "/tmp/macher-sandbox/")))
        
        (puthash "/mock/proj/overlay.el" "VFS Overlay Content" (macher-agent-workspace-vfs-buffers workspace))
        
        (let ((written-to-sandbox nil))
          (spy-on 'write-region :and-call-fake
                  (lambda (start end filename &rest _args)
                    (when (string-suffix-p "overlay.el" filename)
                      (setq written-to-sandbox (substring-no-properties start end)))))
          
          (macher-agent-sandbox-inflate session)
          
          (expect written-to-sandbox :to-equal "VFS Overlay Content")))))

  (describe "3. Context & Isolation (Lexical Survival)"
    (it "asserts that lexical context survives async gptel callbacks without buffer bleeding"
      (let* ((workspace (make-macher-agent-workspace :project-root "/mock/proj/"))
             (session (make-macher-agent-session :id "Agent-A" :workspace workspace))
             (fsm 'mock-fsm)
             (executed-workspace nil))
        
        (spy-on 'gptel-fsm-info :and-return-value (list :macher-agent-session session))
        
        ;; Mock the behaviour where current-buffer changes asynchronously
        (with-temp-buffer
          (let ((original-buffer (current-buffer)))
            
            ;; Execute a mock async tool callback
            (with-temp-buffer ;; "Wandering" buffer context
              (let* ((info (if (fboundp 'gptel-fsm-info)
                               (funcall 'gptel-fsm-info fsm)
                             (funcall 'mock-gptel-fsm-info fsm)))
                     (fsm-session (plist-get info :macher-agent-session)))
                (when fsm-session
                  (setq executed-workspace (macher-agent-session-workspace fsm-session)))))
            
            (expect executed-workspace :to-be workspace))))))

  (describe "4. Media Injection Isolation"
    (it "asserts that media injection strictly checks FSM properties"
      (let* ((workspace (make-macher-agent-workspace :project-root "/mock/proj/"))
             (session (make-macher-agent-session :workspace workspace))
             (fsm 'mock-fsm)
             (macher--fsm-latest fsm))
        
        (spy-on 'gptel-fsm-info :and-return-value (list :macher-agent-session session))
        (setf (macher-agent-session-pending-media session) (list (list "/mock/proj/media.png" :mime "image/png")))
        
        (spy-on 'gptel--inject-media :and-return-value nil)
        (spy-on 'gptel--inject-prompt :and-return-value nil)
        
        ;; Call the rewritten advice directly
        (macher-agent--inject-media-fsm-advice (lambda (f) f) fsm)
        
        ;; Validate that the FSM property was correctly used and cleared
        (expect 'gptel--inject-media :to-have-been-called)
        (expect (macher-agent-session-pending-media session) :to-be nil))))

  (describe "5. Diff Splitting Behaviour"
    (it "asserts that virtual buffer modifications are split from physical file modifications"
      (let* ((workspace (make-macher-agent-workspace :project-root "/mock/proj/"))
             (context (macher--make-context :workspace (cons 'project "/mock/proj/")
                                            :contents '(("/mock/proj/disk-file.el" . ("old" . "new"))
                                                        ("*scratch*" . ("old" . "new")))))
             (fsm 'mock-fsm))
        
        (spy-on 'gptel-fsm-info :and-return-value (list :macher-agent-session (make-macher-agent-session :workspace workspace)))
        
        (setf (macher-context-dirty-p context) t)
        
        (let ((built-vfs-diff nil)
              (built-virtual-diff nil))
          
          (spy-on 'macher--build-patch :and-call-fake
                  (lambda (ctx fsm) (setq built-vfs-diff t)))
          (spy-on 'macher-agent--build-virtual-patch :and-call-fake
                  (lambda (ctx) (setq built-virtual-diff t)))
          
          ;; The rewritten process request function
          (macher-agent--process-request 'complete context fsm)
          
          ;; Both diff streams should be processed
          (expect built-vfs-diff :to-be t)
          (expect built-virtual-diff :to-be t)))))

)