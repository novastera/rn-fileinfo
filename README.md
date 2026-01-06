# @novastera-oss/rn-fileinfo

[![npm version](https://badge.fury.io/js/%40novastera-oss%2Frn-fileinfo.svg)](https://badge.fury.io/js/%40novastera-oss%2Frn-fileinfo)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

`@novastera-oss/rn-fileinfo` is a lightweight React Native TurboModule designed for safe and efficient file metadata access on iOS and Android. It focuses on retrieving file information (such as size, name, path, and timestamps) without loading file contents into memory — making it ideal for handling very large files (1GB+), where libraries like `expo-file-system` may crash or become inefficient.

This package is intentionally minimal, providing just the utilities needed for querying file and directory information. It avoids unnecessary complexity (like file I/O operations), making it a reliable and performant addition to apps that need file stats but not full filesystem manipulation.

## Features

* **Cross-platform support**: Works on iOS and Android
* **Safe large file handling**: Retrieves metadata without memory overhead
* **Non-blocking operations**: All functions run on background threads, never blocking the UI
* **Memory efficient**: Only reads file metadata, never loads file contents into memory
* **Batch processing**: Large directories are processed in chunks to prevent memory issues
* **File info retrieval**: Get file size, name, path, and timestamps
* **Directory utilities**: Collect metadata for all files in a base directory in a single call
* **TurboModule ready**: Built with modern React Native standards, autolinking supported
* **Expo-compatible**: Works with Expo managed and bare workflows via autolinking

## Use Cases

* Media apps checking file sizes before upload
* Document management and productivity tools
* Backup or sync apps gathering metadata for many files
* Any app needing fast, reliable file info without heavy filesystem libraries

## Why This Package?

Most filesystem libraries in React Native aim to provide full file I/O (read, write, copy, move, hash, etc.). While useful, they can be overkill — and on iOS, attempting to fetch info for very large files can cause crashes.

`@novastera-oss/rn-fileinfo` solves this by offering a **focused, safe, and efficient alternative**: just the metadata you need, nothing more.

## Installation

### React Native CLI

```bash
npm install @novastera-oss/rn-fileinfo
# or
yarn add @novastera-oss/rn-fileinfo
```

For iOS, you need to install the pods:

```bash
cd ios && pod install
```

### Expo

```bash
npx expo install @novastera-oss/rn-fileinfo
```

The package uses React Native's autolinking, so no additional configuration is needed for Expo projects.

## Usage

### Basic File Information

```typescript
import RnFileinfo from '@novastera-oss/rn-fileinfo';

const fileInfo = await RnFileinfo.getFileInfo('/path/to/your/file.txt');
console.log(fileInfo);
// Output:
// {
//   path: '/path/to/your/file.txt',
//   name: 'file.txt',
//   size: 1024,
//   isFile: true,
//   isDirectory: false,
//   createdAt: 1640995200000,
//   modifiedAt: 1640995200000
// }
```

Or using individual exports:

```typescript
import { getFileInfo } from '@novastera-oss/rn-fileinfo';

const fileInfo = await getFileInfo('/path/to/your/file.txt');
```

### Directory Information

```typescript
import RnFileinfo from '@novastera-oss/rn-fileinfo';

// Get all files in a directory (options object is required)
const files = await RnFileinfo.getDirectoryInfo('/path/to/directory', {
  recursive: true
});
console.log(files);

// Get files recursively with options
const allFiles = await RnFileinfo.getDirectoryInfo('/path/to/directory', {
  recursive: true,
  includeHidden: false,
  maxDepth: 3
});

// Get files with default options (non-recursive, exclude hidden files)
const defaultFiles = await RnFileinfo.getDirectoryInfo('/path/to/directory', {
  recursive: false,
  includeHidden: false
});
```

**Important**: The `getDirectoryInfo` method requires both arguments - the directory path and an options object. You cannot call it with just the path.

### Utility Functions

```typescript
import RnFileinfo from '@novastera-oss/rn-fileinfo';

// Check if a path exists
const pathExists = await RnFileinfo.exists('/path/to/file');
console.log(pathExists); // true or false

// Check if it's a file
const isAFile = await RnFileinfo.isFile('/path/to/file');
console.log(isAFile); // true or false

// Check if it's a directory
const isADirectory = await RnFileinfo.isDirectory('/path/to/directory');
console.log(isADirectory); // true or false
```

### Error Handling

```typescript
import RnFileinfo from '@novastera-oss/rn-fileinfo';

try {
  const fileInfo = await RnFileinfo.getFileInfo('/nonexistent/file.txt');
} catch (error) {
  console.error('Error:', error);
}
```

## API Reference

### Types

The module returns objects with the following structure:

#### `FileInfo`

```typescript
interface FileInfo {
  /** Full path to the file */
  path: string;
  /** Name of the file (without directory path) */
  name: string;
  /** Size of the file in bytes */
  size: number;
  /** Whether the path points to a file (true) or directory (false) */
  isFile: boolean;
  /** Whether the path points to a directory (true) or file (false) */
  isDirectory: boolean;
  /** Creation timestamp in milliseconds since epoch */
  createdAt: number;
  /** Last modification timestamp in milliseconds since epoch */
  modifiedAt: number;
}
```

#### `DirectoryOptions`

```typescript
interface DirectoryOptions {
  /** Whether to include subdirectories recursively */
  recursive?: boolean;
  /** Whether to include hidden files (files starting with '.') */
  includeHidden?: boolean;
  /** Maximum depth for recursive operations (default: unlimited) */
  maxDepth?: number;
}
```

### Functions

All functions are available on the default export `RnFileinfo`:

#### `RnFileinfo.getFileInfo(path: string): Promise<FileInfo>`

Returns file information for a single file.

**Parameters:**
- `path` (string): The file path to get information for

**Returns:** Promise that resolves to `FileInfo` object

#### `RnFileinfo.getDirectoryInfo(path: string, options: DirectoryOptions): Promise<FileInfo[]>`

Returns file information for all files in a directory.

**Parameters:**
- `path` (string): The directory path to scan
- `options` (DirectoryOptions, **required**): Configuration for directory scanning

**Returns:** Promise that resolves to array of `FileInfo` objects

**Note**: The `options` parameter is required. Pass an empty object `{}` for default behavior (non-recursive, exclude hidden files).

#### `RnFileinfo.exists(path: string): Promise<boolean>`

Check if a path exists.

**Parameters:**
- `path` (string): The path to check

**Returns:** Promise that resolves to boolean indicating if path exists

#### `RnFileinfo.isFile(path: string): Promise<boolean>`

Check if a path is a file.

**Parameters:**
- `path` (string): The path to check

**Returns:** Promise that resolves to boolean indicating if path is a file

#### `RnFileinfo.isDirectory(path: string): Promise<boolean>`

Check if a path is a directory.

**Parameters:**
- `path` (string): The path to check

**Returns:** Promise that resolves to boolean indicating if path is a directory

## Performance Characteristics

### **Non-Blocking Architecture**
- All operations run on dedicated background threads
- JavaScript thread is never blocked during file operations
- Uses concurrent queues for optimal performance

### **Memory Efficiency**
- Only reads file metadata (size, timestamps, attributes)
- Never loads file contents into memory
- Large directories are processed in batches of 1000 files to prevent memory spikes
- Uses platform-optimized APIs for minimal overhead

### **CPU Efficiency**
- Leverages native platform APIs for maximum performance
- Minimal object allocation and garbage collection
- Efficient file system calls with minimal overhead

## Platform Notes

### iOS

- **File creation time**: Available and accurate (`createdAt`)
- **Modification time**: Available and accurate (`modifiedAt`)
- Uses dedicated concurrent queue for file operations
- Optimized for handling very large files without memory issues

### Android

- **File creation time**: **Not available** - Android doesn't provide creation time, so `createdAt` returns the same value as `modifiedAt`
- **Modification time**: Available and accurate (`modifiedAt`)
- Uses Java File API for efficient metadata retrieval
- Batch processing prevents memory issues with large directories

### Important Timestamp Differences

| Platform | `createdAt` | `modifiedAt` |
|----------|-------------|--------------|
| **iOS** | ✅ Accurate | ✅ Accurate |
| **Android** | ❌ Uses `modifiedAt` | ✅ Accurate |

**Note**: Due to platform limitations, Android doesn't provide file creation time. The module provides the best available data for each platform while maintaining a consistent API.

## About Novastera

**@novastera-oss/rn-fileinfo** is part of the **Novastera** open-source ecosystem, a modern CRM/ERP SaaS platform designed for the next generation of business applications. Novastera combines cutting-edge file management solutions with comprehensive business management tools, enabling organizations to efficiently handle file metadata and document management in their mobile applications.

### Key Features of Novastera Platform

- **Modern CRM/ERP System**: Comprehensive business management with AI-powered insights and real-time collaboration
- **Efficient File Management**: Enterprise-grade file metadata handling for document management and media processing
- **Mobile-First**: Native iOS and Android applications built with React Native and Turbo Modules
- **Open Source**: Part of Novastera's commitment to open-source innovation and developer-friendly solutions
- **Privacy-Focused**: On-device AI capabilities with no data leaving user devices

This library is currently being used in [Novastera's](https://novastera.com) mobile application, demonstrating its capabilities in production environments. We're committed to providing modern, efficient file metadata solutions that handle large files safely and performantly, helping developers build applications with reliable file information access without memory overhead.

Learn more about Novastera: [https://novastera.com/resources](https://novastera.com/resources)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

Apache 2.0 © [Novastera](https://novastera.com)
