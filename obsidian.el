;;; obsidian.el --- Obsidian Notes interface -*- coding: utf-8; lexical-binding: t; -*-

;; Copyright (c) 2022 Mykhaylo Bilyanskyy <mb@blaster.ai>

;; Author: Mykhaylo Bilyanskyy
;; URL: https://github.com./licht1stein/obsidian.el
;; Keywords: obsidian, pkm, convenience
;; Version: 1.1.2
;; Package-Requires: ((emacs "27.2") (s "1.12.0") (dash "2.13") (org "9.5.3") (markdown-mode "2.6") (elgrep "1.0.0") (yaml "0.5.1"))

;; This file is NOT part of GNU Emacs.

;;; License:
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.


;;; Commentary:
;; Obsidian.el lets you interact with more convenience with markdown files
;; that are contained in Obsidian Notes vault.  It adds autocompletion for
;; tags and links, jumping between notes, capturing new notes into inbox etc.
;;
;; This allows you to use Emacs for editing your notes, leaving the Obsidian
;; app for syncing and doing more specialized stuff, like viewing notes graphs.

;;; Code:
(require 'dash)
(require 's)

(require 'cl-lib)

(require 'org)
(require 'markdown-mode)

(require 'elgrep)
(require 'yaml)

;; Clojure style comment
(defmacro obsidian-comment (&rest _)
  "Ignore body, yield nil."
  nil)

(defgroup obsidian nil "Obsidian Notes group." :group 'text)

(defcustom obsidian-directory nil
  "Path to Obsidian Notes vault."
  :type 'directory)

(defcustom obsidian-inbox-directory nil
  "Subdir to create notes using `obsidian-capture'."
  :type 'directory)

(eval-when-compile (defvar local-minor-modes))

(defun obsidian-specify-path (&optional path)
  "Specifies obsidian folder PATH to obsidian-folder variable.

When run interactively asks user to specify the path."
  (interactive)
  (->> (or path (read-directory-name "Specify path to Obsidian folder"))
       (expand-file-name)
       (customize-set-value 'obsidian-directory)))
(defvar obsidian--tags-list nil "List of Obsidian Notes tags generated by obsidian.el.")

(defvar obsidian--tag-regex "#[[:alnum:]-_/+]+" "Regex pattern used to find tags in Obsidian files.")

(defvar obsidian--aliases-map (make-hash-table :test 'equal) "Alist of all Obsidian aliases.")

(defun obsidian--clear-aliases-map ()
  "Clears aliases map."
  (interactive)
  (setq obsidian--aliases-map (make-hash-table :test 'equal)))

(defun obsidian--add-alias (alias file)
  "Add ALIAS as key to `obsidian--aliases-map' with FILE as value."
  (puthash alias file obsidian--aliases-map))

(defun obsidian--get-alias (alias &optional dflt)
  "Find ALIAS in `obsidian--aliases-map' with optional DFLT."
  (gethash alias obsidian--aliases-map dflt))

(defun obsidian--all-aliases ()
  "Return all existing aliases (without values)."
  (hash-table-keys obsidian--aliases-map))

;;; File utilities
;; Copied from org-roam's org-roam-descendant-of-p
(defun obsidian-descendant-of-p (a b)
  "Return t if A is descendant of B."
  (unless (equal (file-truename a) (file-truename b))
    (string-prefix-p (replace-regexp-in-string "^\\([A-Za-z]\\):" #'downcase (expand-file-name b) t t)
		     (replace-regexp-in-string "^\\([A-Za-z]\\):" #'downcase (expand-file-name a) t t))))

(defun obsidian-not-trash-p (file)
  "Return t if FILE is not in .trash of Obsidian."
  (not (s-contains-p "/.trash" file)))

(defun obsidian-file-p (&optional file)
  "Return t if FILE is an obsidian.el file, nil otherwise.

If FILE is not specified, use the current buffer's file-path.
FILE is an Org-roam file if:
- It's located somewhere under `obsidian-directory
- It is a markdown .md file
- It is not in .trash
- It is not an Emacs temp file"
  (-when-let* ((path (or file (-> (buffer-base-buffer) buffer-file-name)))
	       (relative-path (file-relative-name path obsidian-directory))
	       (ext (file-name-extension relative-path))
	       (md-p (string= ext "md"))
	       (obsidian-dir-p (obsidian-descendant-of-p path obsidian-directory))
	       (not-trash-p (obsidian-not-trash-p path))
	       (not-temp-p (not (s-contains-p "~" relative-path))))
    t))

(defun obsidian--file-relative-name (f)
  "Take file name F and return relative path for `obsidian-directory'."
  (file-relative-name f obsidian-directory))

(defun obsidian--expand-file-name (f)
  "Take relative file name F and return expanded name."
  (expand-file-name f obsidian-directory))

(defun obsidian-list-all-files ()
  "Lists all Obsidian Notes files that are not in trash.

Obsidian notes files:
- Pass the `obsidian-file-p' check"
  (->> (directory-files-recursively obsidian-directory "\.*$")
       (-filter #'obsidian-file-p)))

(defun obsidian-read-file-or-buffer (&optional file)
  "Return string contents of a file or current buffer.

If FILE is not specified, use the current buffer."
  (if file
      (with-temp-buffer
	(insert-file-contents file)
	(buffer-substring-no-properties (point-min) (point-max)))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun obsidian-find-tags (s)
  "Find all #tags in string.
Argument S string to find tags in."
  (->> (s-match-strings-all obsidian--tag-regex s)
       -flatten))

(defun obsidian-get-yaml-front-matter ()
  "Return the text of the YAML front matter of the current buffer.
Return nil if the front matter does not exist, or incorrectly delineated by
'---'.  The front matter is required to be at the beginning of the file."
  (save-excursion
    (goto-char (point-min))
    (when-let
	((startpoint (re-search-forward "\\(^---\\)" 4 t 1))
	 (endpoint (re-search-forward "\\(^---\\)" nil t 1)))
      (buffer-substring-no-properties startpoint (- endpoint 3)))))

(defun obsidian-find-yaml-front-matter (s)
  "Find YAML front matter in S."
  (if (s-starts-with-p "---" s)
      (let* ((split (s-split-up-to "---" s 2))
	     (looks-like-yaml-p (eq (length split) 3)))
	(if looks-like-yaml-p
	    (->> split
		 (nth 1)
		 yaml-parse-string)))))

(defun obsidian--file-front-matter (file)
  "Check if FILE has front matter and returned parsed to hash-table if it does."
  (let* ((starts-with-dashes-p (with-temp-buffer
				 (insert-file-contents file nil 0 3)
				 (string= (buffer-string) "---"))))
    (let* ((front-matter-s (with-temp-buffer
			     (insert-file-contents file)
			     (obsidian-get-yaml-front-matter))))
      (if front-matter-s
	  (yaml-parse-string front-matter-s)))))

(defun obsidian--update-from-front-matter (file)
  "Takes FILE, parses front matter and then updates anything that needs to be updated.

At the moment updates only `obsidian--aliases-map' with found aliases."
  (let* ((dict (obsidian--file-front-matter file)))
    (if dict
	(let* ((aliases (gethash 'aliases dict))
	       (alias (gethash 'alias dict))
	       (all-aliases (-filter #'identity (append aliases (list alias)))))
	  ;; Update aliases
	  (-map (lambda (al) (if al (progn
				      (obsidian--add-alias (format "%s" al) file)))) all-aliases)))))

(defun obsidian--update-all-from-front-matter ()
  "Take all files in obsidian vault, parse front matter and update."
  (-map #'obsidian--update-from-front-matter (obsidian-list-all-files))
  (message "Obsidian aliases updated."))

(defun obsidian-tag-p (s)
  "Return t if S will match `obsidian--tag-regex', else nil."
  (when (s-match obsidian--tag-regex s)
    t))

(defun obsidian-find-tags-in-file (&optional file)
  "Return all tags in file or current buffer.

If FILE is not specified, use the current buffer"
  (-> (obsidian-read-file-or-buffer file)
      obsidian-find-tags
      -distinct))

(defun obsidian-list-all-tags ()
  "Find all tags in all obsidian files."
  (->> (obsidian-list-all-files)
       (mapcar #'obsidian-find-tags-in-file)
       -flatten
       -distinct))

(defun obsidian-update-tags-list ()
  "Scans entire Obsidian vault and update all tags for completion."
  (->> (obsidian-list-all-tags)
       (setq obsidian--tags-list))
  (message "Obsidian tags updated"))

(define-minor-mode obsidian-mode
  "Toggle minor `obsidian-mode' on and off.

Interactively with no argument, this command toggles the mode.
A positive prefix argument enables the mode, any other prefix
argument disables it.  From Lisp, argument omitted or nil enables
the mode, `toggle' toggles the state."
  ;; The initial value.
  :init-value nil
  :lighter " obs"
  :after-hook (obsidian-update)
  :keymap (make-sparse-keymap))

(defun obsidian-prepare-tags-list (tags)
  "Prepare a list of TAGS with both lower-case and capitalized versions.

Obsidian Notes doesn't considers tags to be the same no matter their case.
Sometimes it's convenient to capitalize a tag, for example when using it
at the start of the sentence.  This function allows completion with both
lower and upper case versions of the tags."
  (let* ((lower-case (->> tags
			  (-map (lambda (s) (s-replace "#" "" s)))
			  (-map #'s-downcase)))
	 (capitalized (-map #'s-capitalize lower-case))
	 (merged (-concat tags lower-case capitalized)))
    (->> merged
	 (-map (lambda (s) (s-concat "#" s)))
	 -distinct)))

(defun obsidian-tags-backend (command &optional arg &rest ignored)
  "Completion backend for company used by obsidian.el.
Argument COMMAND company command.
Optional argument ARG word to complete.
Optional argument IGNORED this is ignored."
  (interactive (if (and (featurep 'company)
			(fboundp 'company-begin-backend))
		   (company-begin-backend 'obsidian-tags-backend)
		 (error "Company not installed")))
  (cl-case command

    (prefix (when (and
		   (-contains-p local-minor-modes 'obsidian-mode)
		   (looking-back obsidian--tag-regex nil))
	      (match-string 0)))
    (candidates (->> obsidian--tags-list
		     obsidian-prepare-tags-list
		     (-filter (lambda (s) (s-starts-with-p arg s)))))))

(defun obsidian-enable-minor-mode ()
  "Check if current buffer is an `obsidian-file-p' and toggle `obsidian-mode'."
  (when (equal major-mode 'markdown-mode)
    (when (obsidian-file-p)
      (obsidian-mode t))))

(defun obsidian-update ()
  "Command update everything there is to update in obsidian.el (tags, links etc.)."
  (interactive)
  (obsidian-update-tags-list)
  ;; (obsidian-update-aliases)
  (obsidian--update-all-from-front-matter)
  )

(defun obsidian--request-link ()
  "Service function to request user for link iput."
  (let* ((all-files (->> (obsidian-list-all-files) (-map (lambda (f) (file-relative-name f obsidian-directory)))))
	 (region (when (org-region-active-p)
		   (buffer-substring-no-properties (region-beginning) (region-end))))
	 (chosen-file (completing-read "Link: " all-files))
	 (default-description (-> chosen-file file-name-nondirectory file-name-sans-extension))
	 (description (read-from-minibuffer "Description (optional): " (or region default-description))))
    (list :file chosen-file :description description)))

(defun obsidian-insert-wikilink ()
  "Insert a link to file in wikiling format."
  (interactive)
  (let* ((file (obsidian--request-link))
	 (filename (plist-get file :file))
	 (description (plist-get file :description))
	 (no-ext (file-name-sans-extension filename))
	 (link (if (and description (not (s-ends-with-p description no-ext)))
		   (s-concat "[[" no-ext "|" description"]]")
		 (s-concat "[[" no-ext "]]"))))
    (insert link)))

(defun obsidian-insert-link ()
  "Insert a link to file in markdown format."
  (interactive)
  (let* ((file (obsidian--request-link)))
    (-> (s-concat "[" (plist-get file :description) "](" (->> (plist-get file :file) (s-replace " " "%20")) ")")
	insert)))

(defun obsidian-capture ()
  "Create new obsidian note.

In the `obsidian-inbox-directory' if set otherwise in `obsidian-directory' root."
  (interactive)
  (let* ((title (read-from-minibuffer "Title: "))
	 (filename (s-concat obsidian-directory "/" obsidian-inbox-directory "/" title ".md"))
	 (clean-filename (s-replace "//" "/" filename)))
    (find-file (expand-file-name clean-filename) t)))

(defun obsidian-jump ()
  "Jump to Obsidian note."
  (interactive)
  (obsidian-update)
  (let* ((files (obsidian-list-all-files))
	 (dict (make-hash-table :test 'equal))
	 (_ (-map (lambda (f) (puthash (file-relative-name f obsidian-directory) f dict)) files))
	 (choices (-sort #'string< (-distinct (-concat (obsidian--all-aliases) (hash-table-keys dict)))))
	 (choice (completing-read "Jump to: " choices))
	 (target (obsidian--get-alias choice (gethash choice dict))))
    (find-file target)))

(defun obsidian-prepare-file-path (s)
  "Replace %20 with spaces in file path.
Argument S relative file name to clean and convert to absolute."
  (let* ((cleaned-name (s-replace "%20" " " s)))
    cleaned-name))

(defun obsidian--match-files (f all-files)
  "Filter ALL-FILES to return list with same name as F."
  (-filter (lambda (el) (s-ends-with-p f el)) all-files))

(defun obsidian-find-file (f)
  "Take file F and either opens directly or offer choice if multiple match."
  (let* ((all-files (->> (obsidian-list-all-files) (-map #'obsidian--file-relative-name)))
	 (matches (obsidian--match-files f all-files))
	 (file (if (> (length matches) 1)
		   (let* ((choice (completing-read "Jump to: " matches)))
		     choice)
		 f)))
    (-> file obsidian--expand-file-name find-file)))

(defun obsidian-wiki-link-p ()
  "Return non-nil if `point' is at a true wiki link.
A true wiki link name matches `markdown-regex-wiki-link' but does
not match the current file name after conversion.  This modifies
the data returned by `match-data'.  Note that the potential wiki
link name must be available via `match-string'."
  (let ((case-fold-search nil))
    (and (thing-at-point-looking-at markdown-regex-wiki-link)
	 (not (markdown-code-block-at-point-p))
	 (or (not buffer-file-name)
	     (not (string-equal (buffer-file-name)
				(markdown-wiki-link-link)))))))

(defun obsidian-wiki->normal (f)
  "Add extension to wiki link F if none."
  (if (file-name-extension f)
      f
    (s-concat f ".md")))

(defun obsidian-follow-wiki-link-at-point ()
  "Find Wiki Link at point."
  (interactive)
  ;; (obsidian-wiki-link-p)
  (thing-at-point-looking-at markdown-regex-wiki-link)
  (let* ((url (->> (match-string-no-properties 3)
		   s-trim)))
    (if (s-contains-p ":" url)
	(browse-url url)
      (-> url
	  obsidian-prepare-file-path
	  obsidian-wiki->normal
	  message
	  obsidian-find-file))))

(defun obsidian-follow-markdown-link-at-point ()
  "Find and follow markdown link at point."
  (interactive)
  (let ((normalized (s-replace "%20" " " (markdown-link-url))))
    (if (s-contains-p ":" normalized)
	(browse-url normalized)
      (-> normalized
	  obsidian-prepare-file-path
	  obsidian-find-file))))

(defun obsidian-follow-link-at-point ()
  "Follow thing at point if possible, such as a reference link or wiki link.
Opens inline and reference links in a browser.  Opens wiki links
to other files in the current window, or the another window if
ARG is non-nil.
See `markdown-follow-link-at-point' and
`markdown-follow-wiki-link-at-point'."
  (interactive)
  (cond ((markdown-link-p)
	 (obsidian-follow-markdown-link-at-point))
	((obsidian-wiki-link-p)
	 (obsidian-follow-wiki-link-at-point))))

(defun obsidian--grep (re)
  "Find RE in the Obsidian vault."
  (elgrep obsidian-directory "\.md" re :recursive t :case-fold-search t :exclude-file-re "~"))

(defun obsidian-search ()
  "Search Obsidian vault for input."
  (interactive)
  (let* ((query (-> (read-from-minibuffer "Search query or regex: ")))
	 (results (obsidian--grep query)))
    (message (s-concat "Found " (pp-to-string (length results)) " matches"))
    (let* ((choice (completing-read "Select file: " results)))
      (obsidian-find-file choice))))

(defun obsidian-tag-find ()
  "Find all notes with a tag."
  (interactive)
  (obsidian-update-tags-list)
  (let* ((tag (completing-read "Select tag: " (->> obsidian--tags-list (-map 's-downcase) -distinct (-sort 'string-lessp))))
	 (results (obsidian--grep tag))
	 (choice (completing-read "Select file: " results)))
    (obsidian-find-file choice)))

;;;###autoload
(define-globalized-minor-mode global-obsidian-mode obsidian-mode obsidian-enable-minor-mode)

(when (boundp 'company-backends)
  (add-to-list 'company-backends 'obsidian-tags-backend))

;; (obsidian-comment
;;  (use-package obsidian
;;    :ensure nil
;;    :config
;;    (obsidian-specify-path "./tests/test_vault")
;;    (global-obsidian-mode t)
;;    :custom
;;    (obsidian-inbox-directory "Inbox")
;;    :bind (:map obsidian-mode-map
;; 	       ;; Replace C-c C-o with Obsidian.el's implementation. It's ok to use another key binding.
;; 	       ("C-c C-o" . obsidian-follow-link-at-point)
;; 	       ;; If you prefer you can use `obsidian-insert-wikilink'
;; 	       ("C-c C-l" . obsidian-insert-link))))

(provide 'obsidian)
;;; obsidian.el ends here
