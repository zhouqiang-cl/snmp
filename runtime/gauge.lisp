;;;; -*- Mode: Lisp -*-
;;;; $Id: gauge.lisp 838 2011-03-14 17:45:50Z binghe $

(in-package :asn.1)

(defclass gauge (number-type) ())

(defun gauge (v)
  (make-instance 'gauge :value v))

(defmethod ber-encode ((value gauge))
  (multiple-value-bind (v l) (ber-encode-integer (value-of value))
    (concatenate 'vector
                 (ber-encode-type 1 0 2)
                 (ber-encode-length l)
                 v)))

(defmethod ber-decode-value ((stream stream) (type (eql :gauge)) length)
  (declare (type fixnum length) (ignore type))
  (gauge (ber-decode-integer-value stream length)))

(eval-when (:load-toplevel :execute)
  (install-asn.1-type :gauge 1 0 2))
