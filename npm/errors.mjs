// Operating-system errors in the words Rust's io::Error Display gives them:
// the C library's strerror text and " (os error N)". The core's corpus records
// those words, so the host reports Node's errors the same way.
import { constants } from "node:os";

const darwin = process.platform === "darwin";

/** The strerror text of each common errno name, on this platform. */
const messages = {
  EPERM: "Operation not permitted",
  ENOENT: "No such file or directory",
  ESRCH: "No such process",
  EINTR: "Interrupted system call",
  EIO: "Input/output error",
  ENXIO: darwin ? "Device not configured" : "No such device or address",
  E2BIG: "Argument list too long",
  ENOEXEC: "Exec format error",
  EBADF: "Bad file descriptor",
  ECHILD: "No child processes",
  EAGAIN: "Resource temporarily unavailable",
  ENOMEM: "Cannot allocate memory",
  EACCES: "Permission denied",
  EFAULT: "Bad address",
  ENOTBLK: "Block device required",
  EBUSY: darwin ? "Resource busy" : "Device or resource busy",
  EEXIST: "File exists",
  EXDEV: darwin ? "Cross-device link" : "Invalid cross-device link",
  ENODEV: darwin ? "Operation not supported by device" : "No such device",
  ENOTDIR: "Not a directory",
  EISDIR: "Is a directory",
  EINVAL: "Invalid argument",
  ENFILE: "Too many open files in system",
  EMFILE: "Too many open files",
  ENOTTY: "Inappropriate ioctl for device",
  ETXTBSY: "Text file busy",
  EFBIG: "File too large",
  ENOSPC: "No space left on device",
  ESPIPE: "Illegal seek",
  EROFS: "Read-only file system",
  EMLINK: "Too many links",
  EPIPE: "Broken pipe",
  ERANGE: darwin ? "Result too large" : "Numerical result out of range",
  ENOTSOCK: "Socket operation on non-socket",
  EDESTADDRREQ: "Destination address required",
  EMSGSIZE: "Message too long",
  EPROTOTYPE: "Protocol wrong type for socket",
  ENOPROTOOPT: "Protocol not available",
  EPROTONOSUPPORT: "Protocol not supported",
  ENOTSUP: "Operation not supported",
  EOPNOTSUPP: darwin ? "Operation not supported on socket" : "Operation not supported",
  EAFNOSUPPORT: darwin ? "Address family not supported by protocol family" : "Address family not supported by protocol",
  EADDRINUSE: "Address already in use",
  EADDRNOTAVAIL: darwin ? "Can't assign requested address" : "Cannot assign requested address",
  ENETDOWN: "Network is down",
  ENETUNREACH: "Network is unreachable",
  ENETRESET: darwin ? "Network dropped connection on reset" : "Network dropped connection on reset",
  ECONNABORTED: "Software caused connection abort",
  ECONNRESET: "Connection reset by peer",
  ENOBUFS: "No buffer space available",
  EISCONN: darwin ? "Socket is already connected" : "Transport endpoint is already connected",
  ENOTCONN: darwin ? "Socket is not connected" : "Transport endpoint is not connected",
  ETIMEDOUT: darwin ? "Operation timed out" : "Connection timed out",
  ECONNREFUSED: "Connection refused",
  ELOOP: "Too many levels of symbolic links",
  ENAMETOOLONG: "File name too long",
  EHOSTDOWN: "Host is down",
  EHOSTUNREACH: "No route to host",
  ENOTEMPTY: "Directory not empty",
  EDQUOT: darwin ? "Disc quota exceeded" : "Disk quota exceeded",
  ESTALE: darwin ? "Stale NFS file handle" : "Stale file handle",
  ENOLCK: "No locks available",
  ENOSYS: "Function not implemented",
  EILSEQ: darwin ? "Illegal byte sequence" : "Invalid or incomplete multibyte or wide character",
  ECANCELED: darwin ? "Operation canceled" : "Operation canceled",
  EINPROGRESS: "Operation now in progress",
  EALREADY: "Operation already in progress",
  EPROTO: "Protocol error",
};

/** Name-resolution failures, which Rust reports without an errno. */
const lookup = {
  ENOTFOUND: darwin ? "nodename nor servname provided, or not known" : "Name or service not known",
  EAI_AGAIN: "Temporary failure in name resolution",
  EAI_FAIL: "Non-recoverable failure in name resolution",
  EAI_NODATA: darwin ? "nodename nor servname provided, or not known" : "No address associated with hostname",
};

/** The Rust Display text of an errno name, such as "No such file or directory (os error 2)". */
export function osErrorText(code) {
  const number = constants.errno[code];
  const message = messages[code];
  if (number !== undefined && message !== undefined) return `${message} (os error ${number})`;
  if (number !== undefined) return `${code} (os error ${number})`;
  return code;
}

/** The Rust Display text of a Node error: its errno's words, or its message. */
export function errorText(error) {
  if (error && typeof error.code === "string") {
    if (lookup[error.code]) return `failed to lookup address information: ${lookup[error.code]}`;
    if (constants.errno[error.code] !== undefined) return osErrorText(error.code);
  }
  return error instanceof Error ? error.message : String(error);
}

/** The innermost cause of an error; of several attempts, the last one's. */
export function rootCause(error) {
  let current = error;
  for (;;) {
    if (current instanceof AggregateError && current.errors.length > 0)
      current = current.errors[current.errors.length - 1];
    else if (current && current.cause !== undefined && current.cause !== null) current = current.cause;
    else return current;
  }
}

/** An error's message followed by each cause's, joined with ": ", as Ironframe's Rust reason. */
export function chainText(error) {
  const parts = [];
  for (let current = error; current; current = current.cause) {
    const text = errorText(current);
    if (text && parts[parts.length - 1] !== text) parts.push(text);
    if (!(current instanceof Error)) break;
  }
  return parts.join(": ") || String(error);
}
