;;;; -*- Mode: Lisp -*-
;;;; $Id: integer.lisp 838 2011-03-14 17:45:50Z binghe $

(in-package :asn.1)

(defclass asn.1-integer (number-type)
  ())

(defmethod plain-value ((object integer) &key default)
  (declare (ignore default))
  object)

(defmethod ber-equal ((a integer) (b integer)) (= a b))

;;; FIXME: (BER-ENCODE-INTEGER -1) will hand forever
(defun ber-encode-integer (value)
  (declare (type integer value))
  (labels ((iter (n acc l)
             (if (zerop n)
               (if (plusp (logand (car acc) #b10000000))
                 (values (cons #x00 acc) (1+ l))
                 (values acc l))
               (multiple-value-bind (q r) (floor n 256)
                 (iter q (cons r acc) (1+ l))))))
    (if (zerop value)
      (values (list 0) 1)
      (iter value nil 0))))

(defmethod ber-encode ((value integer))
  "Encode a plus integer, we don't support minus integer though ASN.1 support it"
  (assert (<= 0 value))
  (multiple-value-bind (v l) (ber-encode-integer value)
    (concatenate 'vector
                 (ber-encode-type 0 0 +asn-integer+)
                 (ber-encode-length l)
                 v)))

(defun ber-decode-integer-value (stream length)
  (declare (type stream stream)
           (type fixnum length))
  (labels ((iter (i acc)
             (if (= i length) acc
               (iter (1+ i) (logior (ash acc 8) (read-byte stream))))))
    (iter 0 0)))

(defmethod ber-decode-value ((stream stream) (type (eql :integer)) length)
  (declare (type fixnum length) (ignore type))
  (ber-decode-integer-value stream length))

(eval-when (:load-toplevel :execute)
  (install-asn.1-type :integer 0 0 +asn-integer+))
