module.exports = {
  preset: '@react-native/jest-preset',
  roots: ['<rootDir>/mobile'],
  testMatch: ['**/__tests__/**/*.test.[jt]s?(x)'],
  clearMocks: true,
};
