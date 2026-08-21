import { NitroModules } from 'react-native-nitro-modules';
import {
  getUnzip,
  type UnzipProgress,
  type UnzipResult,
  type ZipProgress,
  type ZipResult,
} from '../index';

// Mock the NitroModules dependency
const mockUnzip = {
  extract: jest.fn(),
  extractWithPassword: jest.fn(),
  zip: jest.fn(),
  zipWithPassword: jest.fn(),
};

jest.mock('react-native-nitro-modules', () => ({
  NitroModules: {
    createHybridObject: jest.fn(() => mockUnzip),
  },
}));

describe('react-native-nitro-unzip', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  describe('getUnzip', () => {
    it('returns a factory object', () => {
      const unzip = getUnzip();
      expect(unzip).toBeDefined();
      expect(unzip).toBe(mockUnzip);
    });

    it('creates a HybridObject with the correct name', () => {
      getUnzip();
      expect(NitroModules.createHybridObject).toHaveBeenCalledWith('Unzip');
    });
  });

  describe('Unzip factory methods', () => {
    it('has extract method', () => {
      const unzip = getUnzip();
      expect(typeof unzip.extract).toBe('function');
    });

    it('has extractWithPassword method', () => {
      const unzip = getUnzip();
      expect(typeof unzip.extractWithPassword).toBe('function');
    });

    it('has zip method', () => {
      const unzip = getUnzip();
      expect(typeof unzip.zip).toBe('function');
    });

    it('has zipWithPassword method', () => {
      const unzip = getUnzip();
      expect(typeof unzip.zipWithPassword).toBe('function');
    });
  });

  describe('extract returns task-like object', () => {
    it('calls extract with correct arguments', () => {
      const unzip = getUnzip();
      unzip.extract('/path/to/zip', '/path/to/dest');
      expect(mockUnzip.extract).toHaveBeenCalledWith(
        '/path/to/zip',
        '/path/to/dest',
      );
    });

    it('calls extractWithPassword with correct arguments', () => {
      const unzip = getUnzip();
      unzip.extractWithPassword('/path/to/zip', '/path/to/dest', 'secret');
      expect(mockUnzip.extractWithPassword).toHaveBeenCalledWith(
        '/path/to/zip',
        '/path/to/dest',
        'secret',
      );
    });

    it('calls zip with correct arguments', () => {
      const unzip = getUnzip();
      unzip.zip('/path/to/source', '/path/to/out.zip');
      expect(mockUnzip.zip).toHaveBeenCalledWith(
        '/path/to/source',
        '/path/to/out.zip',
      );
    });

    it('calls zipWithPassword with correct arguments', () => {
      const unzip = getUnzip();
      unzip.zipWithPassword('/path/to/source', '/path/to/out.zip', 'secret');
      expect(mockUnzip.zipWithPassword).toHaveBeenCalledWith(
        '/path/to/source',
        '/path/to/out.zip',
        'secret',
      );
    });
  });

  describe('type exports', () => {
    // These tests verify the type exports compile correctly.
    // If they don't exist, TypeScript would fail during build.
    it('UnzipProgress type has expected shape', () => {
      const progress: UnzipProgress = {
        extractedFiles: 10,
        totalFiles: 100,
        progress: 0.1,
        speed: 50,
        processedBytes: 1024,
      };
      expect(progress.progress).toBe(0.1);
    });

    it('UnzipResult type has expected shape', () => {
      const result: UnzipResult = {
        success: true,
        extractedFiles: 100,
        totalFiles: 100,
        duration: 5000,
        averageSpeed: 20,
        totalBytes: 10240,
      };
      expect(result.success).toBe(true);
    });

    it('ZipProgress type has expected shape', () => {
      const progress: ZipProgress = {
        compressedFiles: 5,
        totalFiles: 10,
        progress: 0.5,
        speed: 25,
      };
      expect(progress.progress).toBe(0.5);
    });

    it('ZipResult type has expected shape', () => {
      const result: ZipResult = {
        success: true,
        compressedFiles: 10,
        totalFiles: 10,
        duration: 3000,
        averageSpeed: 3.3,
        totalBytes: 5120,
      };
      expect(result.success).toBe(true);
    });
  });
});
