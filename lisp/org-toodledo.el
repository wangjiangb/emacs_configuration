;;; org-toodledo.el - Toodledo integration for Emacs Org mode
;; (c) 2010 Sacha Chua (sacha@sachachua.com)
;;
;; This file is not part of GNU Emacs.

;; This is free software; you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free
;; Software Foundation; either version 2, or (at your option) any later
;; version.
;;
;; This is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
;; for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
;; MA 02111-1307, USA.

;; How to use:
;; 1. Customize org-toodledo-userid and org-toodledo-password
;; 2. Open a blank org file.
;; 3. Call org-toodledo-initialize-org
;; Call org-toodledo-update to bring in new/updated tasks (skips locally modified tasks newer than updated)
;; Call org-toodledo-sync-task to create or update the current task
;; Call org-toodledo-delete-current-task to delete the current task
;;
;; Doesn't do lots of error trapping. Might be a good idea to version-control your Org file.
;;
;; TOODLEDO ATTRIBUTES and how they are bi-directionally handled
;; Context: Handled by tags (ex:   :@work:  :@errands:)
;;   - will create new contexts if necessary
;; Task status: Mapped to TODO state.
;;   See org-toodledo-status-to-string and org-toodledo-parse-current-task for the mapping
;;   You will probably want something like this in your ~/.emacs:
;; (setq org-todo-keywords
;;      '((sequence
;;         "TODO(t)"  ; next action
;;         "PLAN(-)"
;;         "STARTED(s)"
;;         "WAITING(w@/!)"
;;         "POSTPONED(p)" "SOMEDAY(s@/!)" "|" "DONE(x!)" "CANCELLED(c@)")
;;      (type "DELEGATED(d@!)" "DONE(x)")))
;; Length: Mapped to effort
;; Priority: Mapped to [#A], [#B], or [#C]. (TODO: Change this to five levels of priority to match Toodledo)
;; Start date: Mapped to "SCHEDULED"
;; Due date: Mapped to "DEADLINE"
;; Tags: Mapped to tags
;; Note: Mapped to todo text. May get confused by asterisks, so don't use any starting asterisks in your body text.
;;   (or anything that looks like an Org headline).
;; Completed: Mapped to DONE todo state.
;;
;; TODO:
;; - [ ] Double-check new/changed/deleted task updating, still seems buggy
;; - [ ] Test, test, test - maybe make test harness?
;; - [ ] Move status<->string mapping to a variable - lookups are better than logic
;; - [ ] Make sure sync timestamps aren't getting updated more often than needed
;; - [ ] Suggest some kind of hook to make it easier to mark a task as locally modified

(require 'org)
(require 'xml)
(defcustom org-toodledo-userid ""
  "UserID from Toodledo: http://www.toodledo.com/info/api_doc.php"
  :group 'org-toodledo
  :type 'string)

(defcustom org-toodledo-password ""
  "Password for Toodledo."
  :group 'org-toodledo
  :type 'string)

(defvar org-toodledo-token-expiry nil "Expiry time for authentication token.")
(defvar org-toodledo-token nil "Authentication token.")
(defvar org-toodledo-key nil "Authentication key.")

(require 'url)
(require 'url-http)

(defun org-toodledo-initialize-org ()
  "Replace buffer contents with Toodledo tasks."
  (interactive)
  (delete-region (point-min) (point-max))
  (let ((account-info (org-toodledo-get-account-info))
        (server-info (org-toodledo-get-server-info))
        (tasks (org-toodledo-get-tasks '(("notcomp" . "1")))))
    (insert "* Toodledo\n"
            ":PROPERTIES:\n"
            ":Last-modified: " (cdr (assoc "lastaddedit" account-info)) "\n"
            ":Last-deleted: " (cdr (assoc "lastdelete" account-info)) "\n"
            ":Last-sync: " (cdr (assoc "unixtime" server-info)) "\n"
            ":END:\n")
    (insert (mapconcat 'org-toodledo-task-to-string tasks "\n"))))

(defun org-toodledo-get-token ()
  "Retrieve authentication token valid for four hours."
  (if (and org-toodledo-token
           org-toodledo-token-expiry
           (time-less-p (current-time) org-toodledo-token-expiry))
      org-toodledo-token
    ;; Else retrieve a new token
    (let ((response
            (with-current-buffer
                (url-retrieve-synchronously
                 (concat "http://api.toodledo.com/api.php?method=getToken;userid="
                         org-toodledo-userid))
              (xml-parse-region (point-min) (point-max)))))
      (if (equal (car (car response)) 'error)
          (progn
            (setq org-toodledo-token nil
                  org-toodledo-key nil
                  org-toodledo-token-expiry nil)
            (error "Could not log in to Toodledo: %s" (elt (car response) 2)))
        (setq org-toodledo-token
              (elt (car response) 2))
        (setq org-toodledo-key (org-toodledo-key)
              ;; Set the expiry time
              org-toodledo-token-expiry
              (seconds-to-time
               (+ (time-to-seconds (current-time))
                  (* 60 60 4)))))   ;; four hours
      org-toodledo-token)))

(defun org-toodledo-key ()
  "Return authentication key used for each request."
  (if (and org-toodledo-token
           org-toodledo-token-expiry
           (time-less-p (current-time) org-toodledo-token-expiry)
           org-toodledo-key)
      org-toodledo-key
    (setq org-toodledo-key
          (md5 (concat (md5 org-toodledo-password)
                       org-toodledo-token
                       org-toodledo-userid)))))

(defun org-toodledo-get-url (method-name &optional params)
  "Return URL for METHOD-NAME and PARAMS."
  (org-toodledo-get-token)
  (concat "http://api.toodledo.com/api.php?method="
          (w3m-url-encode-string method-name)
          ";key=" (org-toodledo-key)
          (if params
              (concat
               ";"
               (mapconcat (lambda (x)
                            (concat
                             (w3m-url-encode-string (car x)) "="
                             (w3m-url-encode-string (cdr x))))
                          params
                          ";"))
            "")))

(defun org-toodledo-call-method (method-name &optional params)
  "Call METHOD-NAME with PARAMS and return the parsed XML."
  (setq params (cons (cons "unix" "1") params))
  (with-current-buffer
      (url-retrieve-synchronously
       (org-toodledo-get-url method-name params))
    (xml-parse-region (point-min) (point-max))))

(defmacro org-toodledo-defun (function-name api-name description)
  `(defun ,function-name (params)
     ,description
     (org-toodledo-call-method ,api-name params)))

(defun org-toodledo-get-server-info ()
  "Return server information."
  (org-toodledo-convert-xml-result-to-alist
    (car (org-toodledo-call-method "getServerInfo"))))

(defun org-toodledo-get-account-info ()
  "Return server information."
  (org-toodledo-convert-xml-result-to-alist
   (car (org-toodledo-call-method "getAccountInfo"))))

(org-toodledo-defun org-toodledo-add-task "addTask" "Add task with PARAMS.")
(org-toodledo-defun org-toodledo-edit-task "editTask" "Edit task with PARAMS.")
(org-toodledo-defun org-toodledo-delete-task "deleteTask" "Delete task with PARAMS.")

;; (setq temp (org-toodledo-get-tasks '(("notcomp" . "1"))))
;; (setq server-info (org-toodledo-get-server-info))
;; (setq account-info (org-toodledo-get-account-info))
(defun org-toodledo-convert-xml-result-to-alist (info)
  "Convert INFO to an alist."
  (delq nil
        (mapcar
         (lambda (item)
           (if (listp item)
               (cons (symbol-name (car item)) (elt item 2))))
         (xml-node-children (delete "\n\t" info)))))

(defun org-toodledo-get-tasks (&optional params)
  "Retrieve tasks using PARAMS.
Return a list of task alists."
  (mapcar
   'org-toodledo-convert-xml-result-to-alist
   (xml-get-children
    (car (org-toodledo-call-method "getTasks" params))
    'task)))

(defun org-toodledo-get-deleted (&optional params)
  "Retrieve deleted tasks using PARAMS.
Return a list of task alists."
  (mapcar
   'org-toodledo-convert-xml-result-to-alist
   (xml-get-children
    (car (org-toodledo-call-method "getDeleted" params))
    'task)))

(defun org-toodledo-entry-note ()
  "Extract the note for this entry."
  (save-excursion
    (org-back-to-heading)
    (when (looking-at org-complex-heading-regexp)
      (goto-char (match-end 0))
      (let ((text (buffer-substring-no-properties
                   (point)
                   (if (re-search-forward org-complex-heading-regexp nil t)
                       (match-beginning 0)
                     (org-end-of-subtree)))))
        (with-temp-buffer
          (insert text)
          (goto-char (point-min))
          (when (re-search-forward
                 (concat "\\<"
                         (regexp-quote org-deadline-string) " +<[^>\n]+>[ \t]*") nil t)
            (replace-match ""))
          (goto-char (point-min))
          (when (re-search-forward
                 (concat "\\<"
                         (regexp-quote org-scheduled-string) " +<[^>\n]+>[ \t]*") nil t)
            (replace-match ""))
          (goto-char (point-min))
          (while (re-search-forward "\n\n+" nil t)
            (replace-match "\n"))
          (org-export-remove-or-extract-drawers org-drawers nil nil)
          (buffer-substring-no-properties (point-min)
                                          (point-max)))))))

(defun org-toodledo-parse-current-task ()
  "Extract the status and Toodledo ID of the current task."
  (save-excursion
    (org-back-to-heading t)
    (when (and (looking-at org-complex-heading-regexp)
               (match-string 2)) ;; TODO
      (let* (info
             (status (match-string-no-properties 2))
             (priority (match-string-no-properties 3))
             (title (match-string-no-properties 4))
             (tags (match-string-no-properties 5))
             (id (org-entry-get (point) "Toodledo-ID"))
             (contexts (org-toodledo-get-contexts))
             context)
        ;; (add-to-list 'info (cons "title" (match-string-no-properties 1)))
        (if id (add-to-list 'info (cons "id" id)))
        (when tags
          (setq tags
              (delq nil
                    (mapcar
                     (lambda (tag)
                       (if (> (length tag) 0)
                           (if (string-match (org-re "@\\([[:alnum:]_]+\\)") tag)
                               (progn
                                 ;; Not recognized context
                                 (if (null (assoc (match-string 1 tag) contexts))
                                     ;; Create it if it does not yet exist
                                     (let ((result
                                            (org-toodledo-call-method
                                             "addContext"
                                             (list (cons "title" (match-string 1 tag))))))
                                       (if (eq (caar result) 'added)
                                           (setq org-toodledo-contexts
                                                 (cons (cons (match-string 1 tag)
                                                             (elt (car result) 2))
                                                       org-toodledo-contexts)
                                                 contexts org-toodledo-contexts))))
                                   ;; Get the ID of the context
                                 (setq context
                                       (cdr (assoc (match-string 1 tag) contexts)))
                                 nil)
                             tag)))
                     (split-string tags ":")))))
        (setq info
              (list
               (cons "id" id)
               (cons "title" title)
               (cons "length" (org-entry-get (point) "Effort"))
               (cons "context" context)
               (cons "tag" (mapconcat 'identity tags " "))
               (cons "completed" (if (equal status "DONE") "1" "0"))
               (cons "status"
                     (cond
                      ((equal status "STARTED") "2")
                      ((equal status "DELEGATED") "4")
                      ((equal status "SOMEDAY") "8")
                      ((equal status "CANCELLED") "9")
                      ((equal status "PLAN") "3")
                      ((equal status "WAITING") "5")
                      ((equal status "TODO") "1")))
               (cons "priority"
                     (cond
                      ((equal priority "[#A]") "2")
                      ((equal priority "[#B]") "1")
                      ((equal priority "[#C]") "0")))
               (cons "note"
                     (org-toodledo-entry-note))))
        (when (org-entry-get nil "DEADLINE")
          (setq info (cons (cons "duedate"
                                 (substring (org-entry-get nil "DEADLINE")
                                            0 10)) info)))
        (when (org-entry-get nil "SCHEDULED")
          (setq info (cons (cons "startdate"
                                 (substring (org-entry-get nil "SCHEDULED")
                                            0 10)) info)))
        info))))

(defun org-toodledo-sync ()
  "Synchronize all tasks."
  ;; Retrieve all tasks
  ;; For each task in the current buffer
  ;;   Synchronize an existing task that has changed
   (let ((regexp (concat "^\\*+[ \t]+\\(" org-todo-regexp "\\)")))
    (goto-char (point-min))
    (while (re-search-forward regexp nil t)
      (org-toodledo-sync-task))))

(defun org-toodledo-update ()
  "Insert new tasks and update previous tasks."
  (interactive)
  (let* ((server-info (org-toodledo-get-server-info))
         (account-info (org-toodledo-get-account-info))
         (changed (org-toodledo-account-changed account-info))
         (last-deleted (string-to-number (or (org-entry-get-with-inheritance "Last-deleted") "0")))
         (last-modified (string-to-number (or (org-entry-get-with-inheritance "Last-modified") "0")))
         (last-update (string-to-number (or (org-entry-get-with-inheritance "Last-sync") "0")))
         processed)
    ;; If tasks have been deleted or modified, then the Toodledo API
    ;; will give us the timestamps. We need to find out which tasks
    ;; have been deleted or modified since the last time we retrieved
    ;; the list of tasks that have been deleted or modified. We store
    ;; the last times in the properties of the root element.

    (if (and (assoc "deleted" changed) ;; Tasks have been deleted
             (>= (string-to-number (cdr (assoc "deleted" changed))) last-deleted))
        (setq processed
              (append (org-toodledo-process-deleted-tasks
                       last-deleted)
                       processed)))
    (if (and (assoc "modified" changed) ;; Tasks have been added or edited
             (>= (string-to-number (cdr (assoc "modified" changed)))
                last-modified))
        ;; Retrieve added/modified tasks
        (setq processed (append
                         (org-toodledo-process-modified-tasks last-modified) processed)))
    ;; TODO Look for tasks that were modified locally since the last synchronization
    (org-toodledo-process-locally-modified-tasks last-update processed)
    ;; TODO Update timestamps here
    (goto-char (point-min))
    (when (re-search-forward (concat "^\\(" outline-regexp "\\)") nil t)
      (org-entry-put (point)
                     "Last-sync"
                     (cdr (assoc "unixtime" server-info)))
      (when (assoc "lastaddedit" account-info)
        (org-entry-put (point)
                       "Last-modified"
                       (cdr
                        (assoc "lastaddedit" account-info))))
      (when (assoc "lastdelete" account-info)
        (org-entry-put (point)
                         "Last-deleted"
                         (cdr
                          (assoc "lastdelete" account-info)))))))

(defun org-toodledo-process-locally-modified-tasks (last-update processed)
  "Synchronize tasks that were locally modified after LAST-UPDATE.
Skip tasks with IDs in PROCESSED."
  (goto-char (point-min))
  (let ((start (float-time (current-time))))
    (while (re-search-forward org-complex-heading-regexp nil t)
      ;; Look for all tasks in this buffer
      (if (match-string 2)
          ;; Is it a new task, or has it been modified since the last update?
          (let ((id (org-entry-get (point) "Toodledo-ID"))
                (modified (string-to-number (or (org-entry-get (point) "Modified") "")))
                (last-sync (if (org-entry-get (point) "Sync")
                               (string-to-number (org-entry-get (point) "Sync"))
                             0)))
            (if (or (null id)
                    (and (> modified last-sync)
                         (< modified start)
                         (not (member id processed))))
                (save-excursion (org-toodledo-sync-task))))))))

(defun org-toodledo-touch ()
  "Update the current task."
  (interactive)
  (org-entry-put (point) "Modified" (format "%d" (float-time (current-time)))))

(defvar org-toodledo-actually-delete t)
(defun org-toodledo-process-deleted-tasks (timestamp)
  "Remove tasks deleted after TIMESTAMP."
  (delq nil
        (mapcar
         (lambda (task)
           (when (org-toodledo-find-task task)
             (if org-toodledo-actually-delete
                 (delete-region (org-back-to-heading)
                                (if (re-search-forward org-complex-heading-regexp nil t)
                                    (match-beginning 0)
                                  (org-end-of-subtree)))
               (org-entry-delete (point) "Toodledo-ID")
               (org-entry-put (point) "Toodledo-Deleted" (timestamp)))
             (org-toodledo-task-id task)))
         (org-toodledo-get-deleted
          (list (cons "after" (number-to-string timestamp)))))))

(defun org-toodledo-process-modified-tasks (modified)
  "Handle all the tasks that have been modified since MODIFIED."
  (delq nil
        (mapcar
         (lambda (task)
           (if (org-toodledo-find-task task)
               (if (null (org-toodledo-update-task task modified))
                   (org-toodledo-task-id task))
             (org-toodledo-create-task task)))
         (org-toodledo-get-tasks (list (cons "modafter" (number-to-string modified)))))))

(defun org-toodledo-create-task (task)
  "Create a task for TASK."
  (goto-char (point-max))
  (if (point-at-eol) (insert "\n"))
  (insert (org-toodledo-task-to-string task))
  (org-toodledo-task-id task))

(defun org-toodledo-find-task (task)
  "Find the task specified by TASK."
  (goto-char (point-min))
  (re-search-forward
   (concat "^[ \t]*:Toodledo-ID:[ \t]+" (org-toodledo-task-id task) "$")
   nil t))

(defun org-toodledo-account-changed (account-info)
  "Return non-nil if the account has changed since the last check.
The result will be an alist of (\"modified\" . \"timestamp\") if tasks have
been added/edited and (\"deleted\" . \"timestamp\") if tasks have been deleted."
  (let ((last-modified (org-entry-get-with-inheritance "Last-modified"))
        (last-deleted (org-entry-get-with-inheritance "Last-deleted"))
        result)
    (if (> (string-to-number (or (cdr (assoc "lastaddedit" account-info)) "0"))
           (string-to-number (or last-modified "0")))
        (add-to-list 'result (cons "modified" last-modified)))
    (if (> (string-to-number (or (cdr (assoc "lastdelete" account-info)) ""))
           (string-to-number (or last-deleted "0")))
        (add-to-list 'result (cons "deleted" last-deleted)))
    result))

(defun org-toodledo-sync-task (&optional force)
  "Update my Toodledo for the current task."
  (interactive "P")
  (save-excursion
    (let ((task (org-toodledo-parse-current-task)))
      (if (null (org-toodledo-task-id task))
          ;; New task, create it
          (let ((result (org-toodledo-add-task task)))
            (when (eq (elt (car result) 0) 'added)
              (org-entry-put (point) "Toodledo-ID" (elt (car result) 2))
              (org-entry-put (point) "Sync"
                             (format "%d" (float-time (current-time)) 1000))))
        ;; Old task, update
        (when (org-toodledo-success-p (org-toodledo-edit-task task))
          (if (equal (org-toodledo-task-completed task) "1")
              (org-entry-put (point) "Completed" "1")
            (org-entry-put (point) "Status" (org-toodledo-task-status task)))
          (org-entry-put (point) "Sync"
                         (format "%d" (float-time (current-time)) 1000)))))))

;; (assert (equal (org-toodledo-format-date "2003-08-12") "<2003-08-12 Tue>"))
(defun org-toodledo-format-date (date &optional repeat)
  "Return yyyy-mm-dd day for DATE."
  (concat
   "<"
   (format-time-string
    "%Y-%m-%d %a"
    (cond
     ((listp date) date)
     ((numberp date) (seconds-to-time date))
     ((and (stringp date)
           (string-match "^[0-9]+$" date))
      (seconds-to-time (string-to-number date)))
     (t (apply 'encode-time (org-parse-time-string date)))))
   (if repeat (concat " " repeat) "")
   ">"))

;; (mapconcat 'org-toodledo-task-to-string temp "\n")
;; (setq task (elt temp 2))
;; (org-toodledo-task-to-string task)
(defun org-toodledo-task-to-string (task &optional level)
  "Return an Org-formatted version of TASK."
  (let* ((repeat (string-to-number (org-toodledo-task-repeat task)))
         (rep-advanced (org-toodledo-task-repeat-advanced task))
         (repeat-string (org-toodledo-repeat-to-string repeat rep-advanced))
         (priority (org-toodledo-task-priority task)))
    (concat
     (make-string (or level 2) ?*) " "
     (org-toodledo-status-to-string task) " "
     (cond
      ((equal priority "-1") "")
      ((equal priority "0") "[#C] ")
      ((equal priority "1") "[#B] ")
      ((equal priority "2") "[#A] ")
      ((equal priority "3") "[#A] "))
     (org-toodledo-task-title task)
     (if (org-toodledo-task-context task)
         (concat " :@" (org-toodledo-task-context task) ":")
       "")
     "\n"
     (if (and (org-toodledo-task-duedate task)
              (not (equal (org-toodledo-task-duedate task) ""))
              (not (< (string-to-number (org-toodledo-task-duedate task)) 0)))
         (concat org-deadline-string " "
                 (org-toodledo-format-date
                  (org-toodledo-task-duedate task)
                  repeat-string)
                 "\n")
       "")
     (or (org-toodledo-task-note task) "") "\n"
     ":PROPERTIES:\n"
     ":Toodledo-ID: " (org-toodledo-task-id task) "\n"
     ":Modified: " (org-toodledo-task-modified task) "\n"
     ":Sync: " (format "%d" (float-time (current-time))) "\n"
     ":Effort: " (org-toodledo-task-length task) "\n"
     ":END:\n"
     )))

;; (assert (equal (org-toodledo-repeat-to-string 0) ""))
;; (assert (equal (org-toodledo-repeat-to-string 1) "+1w"))
;; (assert (equal (org-toodledo-repeat-to-string 2) "+1m"))
;; (assert (equal (org-toodledo-repeat-to-string 3) "+1y"))
;; (assert (equal (org-toodledo-repeat-to-string 4) "+1d"))
;; (assert (equal (org-toodledo-repeat-to-string 5) "+2w"))
;; (assert (equal (org-toodledo-repeat-to-string 6) "+2m"))
;; (assert (equal (org-toodledo-repeat-to-string 7) "+6m"))
;; (assert (equal (org-toodledo-repeat-to-string 8) "+3m"))
;; (assert (equal (org-toodledo-repeat-to-string 108) ".+3m"))
;; (assert (equal (org-toodledo-repeat-to-string 101) ".+1w"))
;; (assert (equal (org-toodledo-repeat-to-string 0) ""))

(defconst org-toodledo-repeat-intervals '("" "+1w" "+1m" "+1y" "+1d" "+2w" "+2m" "+6m" "+3m"))
(defun org-toodledo-status-to-string (task)
  (let ((comp (org-toodledo-task-completed task))
        (status (string-to-number (org-toodledo-task-status task))))
    (cond
     ((not (or (null comp) (equal comp "") (equal comp "0"))) "DONE")
     ((= status 0) "TODO")
     ((= status 1) "TODO")
     ((= status 2) "STARTED")
     ((= status 3) "PLAN")
     ((= status 4) "DELEGATED")
     ((= status 5) "WAITING")
     ((= status 6) "PLAN")  ; hold
     ((= status 7) "SOMEDAY")  ; postponed
     ((= status 8) "SOMEDAY")
     ((= status 9) "CANCELLED")
     )))

(defun org-toodledo-repeat-to-string (repeat &optional rep-advanced)
  "Turn TASK into a repeat sequence."
  (cond
   ((= repeat 0) nil)
   ((> repeat 100) (concat "+" (org-toodledo-repeat-to-string (mod repeat 100) rep-advanced)))
   ((and (= repeat 50) rep-advanced)
    (cond
     ((string-match "Every \\([0-9]+\\) week" rep-advanced)
      (concat "+" (match-string 1 rep-advanced) "w"))
     ((string-match "Every \\([0-9]+\\) month" rep-advanced)
      (concat "+" (match-string 1 rep-advanced) "m"))
     ((string-match "Every \\([0-9]+\\) year" rep-advanced)
      (concat "+" (match-string 1 rep-advanced) "y"))
     ((string-match "Every \\([0-9]+\\) day" rep-advanced)
      (concat "+" (match-string 1 rep-advanced) "d"))
     (t rep-advanced)))
   (t (elt org-toodledo-repeat-intervals repeat))))

(defun org-toodledo-delete-current-task ()
  "Delete the current task."
  (interactive)
  (org-back-to-heading t)
  (let ((task (org-toodledo-parse-current-task)))
    (and (> (length (org-toodledo-task-id task)) 0)
         (org-toodledo-success-p (org-toodledo-delete-task task)))
    (delete-region
     (point)
     (if (and (end-of-line)
              (re-search-forward org-complex-heading-regexp nil t))
         (match-beginning 0)
       (org-end-of-subtree t t)
       (point)))))

(defun org-toodledo-task-get-prop (task prop) (cdr (assoc prop task)))
(defmacro org-toodledo-task-prop-defun (field)
  `(defun ,(intern (concat "org-toodledo-task-" field)) (task)
     (cdr (assoc ,field task))))

(defun org-toodledo-success-p (result)
  "Return non-nil if RESULT indicates success."
  (eq (car (car result)) 'success))

(org-toodledo-task-prop-defun "id")
(org-toodledo-task-prop-defun "title")
(org-toodledo-task-prop-defun "status")
(org-toodledo-task-prop-defun "completed")
(org-toodledo-task-prop-defun "repeat")
(org-toodledo-task-prop-defun "context")
(org-toodledo-task-prop-defun "duedate")
(org-toodledo-task-prop-defun "modified")
(org-toodledo-task-prop-defun "priority")
(org-toodledo-task-prop-defun "note")
(org-toodledo-task-prop-defun "length")
;; defun'd separately because of the change in name
(defun org-toodledo-task-repeat-advanced (task)
  (cdr (assoc "rep_advanced" task)))

(defvar org-toodledo-contexts nil "An alist of (context . id).")
(defun org-toodledo-get-contexts (&optional force)
  "Store an alist of (context . id) in `org-toodledo-contexts'.
Reload if FORCE is non-nil."
  (if (or force (null org-toodledo-contexts))
      (setq org-toodledo-contexts
            (mapcar
             (lambda (node)
               (cons
              (car (xml-node-children node))
              (xml-get-attribute node 'id)))
             (xml-get-children (car
                                (org-toodledo-call-method "getContexts")) 'context)))
    org-toodledo-contexts))

(defun org-toodledo-agenda-touch ()
  "Update the Modified timestamp for the current entry in the agenda."
  (org-agenda-check-type t 'agenda 'timeline)
  (org-agenda-check-no-diary)
  (let* ((marker (or (org-get-at-bol 'org-marker)
                     (org-agenda-error)))
         (buffer (marker-buffer marker))
         (pos (marker-position marker)))
    (org-with-remote-undo buffer
     (with-current-buffer buffer
       (widen)
       (goto-char pos)
       (if (org-entry-get (point) "Modified")
           (org-entry-put (point) "Modified" (format "%d" (float-time (current-time)))))))))

(defun org-toodledo-update-task (task &optional last-update)
  (let* ((modified (string-to-number (or (org-entry-get (point) "Modified") "")))
         (last-sync (if (org-entry-get (point) "Sync")
                        (string-to-number (org-entry-get (point) "Sync"))
                      0))
         (level (car (org-heading-components)))
         (locally-modified (> modified last-sync)))
    ;; Locally modified? keep
    (if locally-modified
        nil
      ;; Not locally modified? replace
      ;; Figure out what our level is
      (delete-region (org-back-to-heading)
                     (progn (goto-char (match-end 0))
                            (if (re-search-forward org-complex-heading-regexp nil t)
                                (goto-char (match-beginning 0))
                              (org-end-of-subtree))))
      (insert (org-toodledo-task-to-string task level))
      t)))

(provide 'org-toodledo)
