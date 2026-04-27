import { Entity, Column, PrimaryGeneratedColumn } from 'typeorm';

@Entity()
export class Stand {
  @PrimaryGeneratedColumn()
  id: number;

  @Column({ unique: true })
  name: string;

  @Column({ type: 'float' })
  x: number;

  @Column({ type: 'float' })
  y: number;
}