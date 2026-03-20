import RnFileinfo from './NativeRnFileinfo';


// Export the native module directly
export default RnFileinfo;

// Export individual methods for convenience
export const getFileInfo = RnFileinfo.getFileInfo;
export const getDirectoryInfo = RnFileinfo.getDirectoryInfo;
export const exists = RnFileinfo.exists;
export const isFile = RnFileinfo.isFile;
export const isDirectory = RnFileinfo.isDirectory;

// Export download manager APIs
export * from './download';
